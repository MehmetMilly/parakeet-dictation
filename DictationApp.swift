import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
import CoreGraphics
import IOKit.hid

private let rightCommand: UInt64 = 0x00000010
private let rightOption: UInt64 = 0x00000040
private let otherModifiers: UInt64 = 0x00000001 | 0x00000002 | 0x00000004 | 0x00000008 | 0x00000020 | 0x00002000
private let sampleRate = 16_000
private let minimumSeconds = 0.35
private let maximumSeconds = 600.0
private let recordingLimit = 40
private let chunkSeconds = 20.0
private let chunkHoldback = 2.5
private let chunkOverlap = 1.2
private let recordingName: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
    return formatter
}()

private let controller = DictationController()

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<DictationController>.fromOpaque(userInfo).takeUnretainedValue()
    owner.receive(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

final class DictationController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let hintMenuItem = NSMenuItem(
        title: "Press Right ⌘ and Right ⌥ to start, press again to finish",
        action: nil,
        keyEquivalent: ""
    )
    private let hud = DictationHUD()
    private let recordingsItem = NSMenuItem(title: "Recordings", action: nil, keyEquivalent: "")
    private var copyLastItem: NSMenuItem?

    private var tap: CFMachPort?
    private var globalMonitor: Any?
    private var arm: DispatchWorkItem?
    private var chordIsDown = false
    private var lastChordPress = Date.distantPast
    private var draining = false
    private var drainGeneration = 0
    private var drainTail: TimeInterval = 0.35
    private var quitting = false
    private var workerRestarts = 0
    private var captureBusy = false
    private var micWatchInstalled = false
    private var sawDeviceSide = false
    private var lastLoggedFlags: UInt64 = .max
    private var accessReady: Bool?
    private var recording = false
    private var engine: AVAudioEngine?
    private var captured: [Float] = []
    private var captureRate: Double = 48_000
    private let audioLock = NSLock()
    private var recordingStarted = Date()

    private var worker: Process?
    private var workerIn: FileHandle?
    private var modelReady = false
    private var requestInFlight = false
    private var queue: [URL] = []
    private var lineBuffer = Data()
    private var pendingPaste: [(String?) -> Void] = []
    private var lastTranscript: String?
    private var chunkTimer: Timer?
    private var flushedCount = 0
    private var utterance = 0
    private var parts: [String] = []
    private var partsExpected = 0
    private var partsReceived = 0
    private var finalQueued = false
    private var utteranceFailed = false
    private var utteranceRecording: URL?

    func start() {
        buildMenu()
        setSymbol("mic.slash")
        statusItem.button?.toolTip = "Parakeet Dictation"
        promptForPermissions()
        installTap()
        watchSystemMicrophone()
        startWorker()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshAccess()
        }
        refreshAccess()
        log("started")
    }

    func shutdown() {
        quitting = true
        disarm()
        stopCapture(transcribe: false)
        if let input = workerIn {
            let body = Data("{\"cmd\":\"quit\"}\n".utf8)
            input.write(body)
        }
        worker?.terminate()
        worker = nil
    }

    // MARK: Hotkey

    func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        let flags = event.flags.rawValue
        let keyDown = type == .keyDown
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        DispatchQueue.main.async { [weak self] in
            self?.handle(flags: flags, keyDown: keyDown, keyCode: keyCode)
        }
    }

    private func handle(flags: UInt64, keyDown: Bool, keyCode: Int64) {
        if (flags & 0x007F) != 0 {
            sawDeviceSide = true
        }
        if keyDown {
            if Self.modifierKeyCodes.contains(keyCode) {
                return
            }
            if recording, keyCode == 53 {
                stopCapture(transcribe: false)
                showTransient("Cancelled")
            }
            disarm()
            return
        }

        if flags != lastLoggedFlags && (flags & 0x00180000) != 0 {
            lastLoggedFlags = flags
            log(String(format: "modifiers %llx", flags))
        }

        let held = Self.chord(flags, allowGeneric: !sawDeviceSide)
        let pressed = held && !chordIsDown
        chordIsDown = held
        guard pressed else { return }
        // One physical click often arrives as two presses a fraction of a
        // second apart, because the modifier flags flicker. The second one
        // was stopping a recording that had just started.
        let now = Date()
        if now.timeIntervalSince(lastChordPress) < 0.75 {
            log("ignored extra shortcut press")
            return
        }
        lastChordPress = now
        if recording {
            log("shortcut stop")
            stopCapture(transcribe: true)
        } else if tap != nil {
            log("shortcut start")
            beginCapture()
        }
    }

    private static let modifierKeyCodes: Set<Int64> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static func chord(_ flags: UInt64, allowGeneric: Bool) -> Bool {
        let blocked = (flags & otherModifiers) != 0
        let right = (flags & rightCommand) != 0 && (flags & rightOption) != 0
        if right && !blocked {
            return true
        }
        let command = (flags & 0x00100000) != 0
        let option = (flags & 0x00080000) != 0
        let shift = (flags & 0x00020000) != 0
        let control = (flags & 0x00040000) != 0
        return allowGeneric && command && option && !shift && !control && !blocked
    }

    private func disarm() {
        arm?.cancel()
        arm = nil
    }

    // MARK: Recording

    private func beginCapture() {
        let session = AVCaptureDevice.authorizationStatus(for: .audio)
        guard session == .authorized else {
            if session == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                showTransient("Allow the microphone")
            } else {
                showTransient("Microphone access is off")
                openPrivacy("Microphone")
            }
            return
        }

        guard !captureBusy else { return }
        captureBusy = true
        defer { captureBusy = false }

        let micName = pinBuiltInMicrophone()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            showTransient("No microphone")
            log("input format was empty")
            return
        }

        utterance += 1
        chunkTimer?.invalidate()
        flushedCount = 0
        parts.removeAll()
        partsExpected = 0
        partsReceived = 0
        finalQueued = false
        utteranceFailed = false
        utteranceRecording = nil
        captured.removeAll(keepingCapacity: true)
        captured.reserveCapacity(Int(format.sampleRate) * 30)
        captureRate = format.sampleRate
        audioLock.lock()
        captured.removeAll(keepingCapacity: true)
        audioLock.unlock()
        log("microphone \(micName ?? "system default")")

        // 120 ms is inside the 100–400 ms range this system accepts. A shorter
        // buffer makes installTap abort the process.
        let frames = AVAudioFrameCount(format.sampleRate * 0.12)
        do {
            try input.__installTap(onBus: 0, bufferSize: frames, format: format, error: ()) { [weak self] buffer, _ in
                self?.take(buffer)
            }
        } catch {
            log("tap failed: \(error.localizedDescription) rate \(format.sampleRate) channels \(format.channelCount)")
            showTransient("Couldn't open the microphone")
            return
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            log("mic failed: \(error.localizedDescription)")
            showTransient("Couldn't open the microphone")
            return
        }

        self.engine = engine
        recording = true
        draining = false
        let hardware = input.presentationLatency + input.auAudioUnit.latency
        let buffer = 0.12
        drainTail = min(0.55, max(0.30, hardware + buffer + 0.08))
        let started = Date()
        recordingStarted = started
        lastChordPress = started
        setSymbol("mic.fill", tint: .systemRed)
        statusMenuItem.title = "Listening…"
        hud.show("Listening", symbol: "mic.fill", tint: .systemRed)
        log(String(format: "listening at %.0f Hz, drain %.0f ms", format.sampleRate, drainTail * 1000))
        chunkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.flushChunk(final: false)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + maximumSeconds) { [weak self] in
            guard let self, self.recording, self.recordingStarted == started else { return }
            self.stopCapture(transcribe: true)
        }
    }

    private func take(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        guard frames > 0, count > 0 else { return }
        var chunk = [Float](repeating: 0, count: frames)
        if count == 1 {
            chunk.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress?.update(from: channels[0], count: frames)
            }
        } else {
            let used = min(count, 2)
            for index in 0..<frames {
                var sum: Float = 0
                for channel in 0..<used {
                    sum += channels[channel][index]
                }
                chunk[index] = sum / Float(used)
            }
        }
        audioLock.lock()
        captured.append(contentsOf: chunk)
        audioLock.unlock()
    }

    private func stopCapture(transcribe: Bool) {
        guard recording else { return }
        // The microphone delivers sound a little after it is spoken. Stopping
        // the tap on the click drops the last word, which is still in that buffer.
        if transcribe && !draining {
            draining = true
            drainGeneration += 1
            let generation = drainGeneration
            let tail = drainTail
            hud.show("…", symbol: "waveform", tint: .white)
            statusMenuItem.title = "Transcribing…"
            DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [weak self] in
                guard let self, self.draining, self.drainGeneration == generation else { return }
                self.finishCapture(transcribe: true)
            }
            return
        }
        finishCapture(transcribe: transcribe)
    }

    private func finishCapture(transcribe: Bool) {
        guard recording else { return }
        recording = false
        draining = false
        drainGeneration += 1
        chunkTimer?.invalidate()
        chunkTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        setSymbol(modelReady ? "mic" : "waveform")
        if !transcribe {
            statusMenuItem.title = modelReady ? "Ready" : "Loading Cohere…"
        }

        audioLock.lock()
        let samples = captured
        let already = flushedCount
        captured.removeAll(keepingCapacity: false)
        flushedCount = 0
        audioLock.unlock()
        let rate = captureRate

        guard transcribe else {
            utterance += 1
            hud.hide()
            return
        }

        let seconds = Double(samples.count) / rate
        if seconds < minimumSeconds {
            hud.hide()
            return
        }

        let voice = resample(samples, from: rate, to: Double(sampleRate))
        let energy = voice.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(voice.count, 1))
        if energy < 0.000001 {
            showTransient("Didn't catch that")
            return
        }
        let stamp = recordingName.string(from: Date())
        var url = recordingsDirectory().appendingPathComponent("\(stamp).wav")
        if FileManager.default.fileExists(atPath: url.path) {
            url = recordingsDirectory().appendingPathComponent("\(stamp)-\(String(UUID().uuidString.prefix(4))).wav")
        }
        do {
            try writeWav(voice, rate: sampleRate, to: url)
        } catch {
            log("wav failed: \(error.localizedDescription)")
            showTransient("Couldn't save the recording")
            return
        }
        utteranceRecording = url
        hud.show("…", symbol: "waveform", tint: .white)
        statusMenuItem.title = "Transcribing…"
        sendRemainder(samples, alreadyFlushed: already, rate: rate, token: utterance)
    }

    private func flushChunk(final: Bool) {
        guard recording, !draining, !final else { return }
        let rate = captureRate
        let hold = Int(chunkHoldback * rate)
        let minimumNew = Int(chunkSeconds * rate)
        audioLock.lock()
        let total = captured.count
        let start = flushedCount
        guard total - start - hold >= minimumNew, start < total - hold else {
            audioLock.unlock()
            return
        }
        let target = total - hold
        let searchFrom = max(start + Int(12 * rate), target - Int(2.5 * rate))
        let cut = quietCut(captured, from: searchFrom, to: target, rate: rate)
        let overlap = start == 0 ? 0 : min(Int(chunkOverlap * rate), start)
        let slice = Array(captured[(start - overlap)..<cut])
        flushedCount = cut
        audioLock.unlock()
        let token = utterance
        log(String(format: "early chunk %.1fs", Double(slice.count) / rate))
        submit(slice, rate: rate, token: token, isFinal: false)
    }

    private func sendRemainder(_ samples: [Float], alreadyFlushed: Int, rate: Double, token: Int) {
        let start = min(max(alreadyFlushed, 0), samples.count)
        if samples.count > start {
            let overlap = start == 0 ? 0 : min(Int(chunkOverlap * rate), start)
            let from = start - overlap
            submit(Array(samples[from..<samples.count]), rate: rate, token: token, isFinal: true)
        } else if partsExpected == 0, !samples.isEmpty {
            submit(samples, rate: rate, token: token, isFinal: true)
        }
        finalQueued = true
        maybeFinishUtterance()
    }

    private func submit(_ samples: [Float], rate: Double, token: Int, isFinal: Bool) {
        let voice = resample(samples, from: rate, to: Double(sampleRate))
        guard !voice.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-part-\(UUID().uuidString).wav")
        do {
            try writeWav(voice, rate: sampleRate, to: url)
        } catch {
            log("chunk wav failed: \(error.localizedDescription)")
            utteranceFailed = true
            return
        }
        partsExpected += 1
        enqueue(url) { [weak self] text in
            guard let self, token == self.utterance else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try? FileManager.default.removeItem(at: url)
            self.partsReceived += 1
            if text == nil {
                self.utteranceFailed = true
                self.parts.append("")
            } else {
                self.parts.append(text ?? "")
            }
            if isFinal {
                self.finalQueued = true
            }
            self.maybeFinishUtterance()
        }
    }

    private func quietCut(_ samples: [Float], from: Int, to: Int, rate: Double) -> Int {
        let start = max(0, min(from, samples.count))
        let end = max(start, min(to, samples.count))
        let window = max(1, Int(rate * 0.04))
        var best = end
        var bestEnergy = Float.greatestFiniteMagnitude
        var index = start
        while index + window <= end {
            var sum: Float = 0
            for sample in samples[index..<(index + window)] {
                sum += sample * sample
            }
            let energy = sum / Float(window)
            if energy < bestEnergy {
                bestEnergy = energy
                best = index
            }
            index += window
        }
        if bestEnergy < 0.0004 {
            return best
        }
        return end
    }

    private func maybeFinishUtterance() {
        guard finalQueued, partsReceived == partsExpected else { return }
        let text = parts.reduce("") { mergeTranscript($0, $1) }
        let url = utteranceRecording
        parts.removeAll()
        partsExpected = 0
        partsReceived = 0
        finalQueued = false
        if utteranceFailed {
            utteranceFailed = false
            if let url {
                storeTranscript(nil, for: url)
            }
            showTransient("Saved the recording")
            statusMenuItem.title = modelReady ? "Ready" : "Loading Cohere…"
            setSymbol(modelReady ? "mic" : "waveform")
            return
        }
        guard !text.isEmpty else {
            showTransient("Didn't catch that")
            statusMenuItem.title = modelReady ? "Ready" : "Loading Cohere…"
            setSymbol("mic")
            return
        }
        if let url {
            storeTranscript(text, for: url)
        }
        lastTranscript = text
        copyLastItem?.isEnabled = true
        hud.hide()
        paste(text)
        if !recording {
            statusMenuItem.title = "Ready"
            setSymbol("mic", title: "")
        }
    }

    private func mergeTranscript(_ left: String, _ right: String) -> String {
        let a = left.split(separator: " ").map(String.init)
        let b = right.split(separator: " ").map(String.init)
        if a.isEmpty { return right.trimmingCharacters(in: .whitespacesAndNewlines) }
        if b.isEmpty { return left.trimmingCharacters(in: .whitespacesAndNewlines) }
        let limit = min(16, a.count, b.count)
        var overlap = 0
        if limit > 0 {
            for count in stride(from: limit, through: 1, by: -1) {
                let suffix = a.suffix(count).map { normalizeWord($0) }
                let prefix = b.prefix(count).map { normalizeWord($0) }
                if suffix == prefix {
                    overlap = count
                    break
                }
            }
        }
        return (a + b.dropFirst(overlap)).joined(separator: " ")
    }

    private func normalizeWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private func watchSystemMicrophone() {
        pinBuiltInMicrophone()
        guard !micWatchInstalled else { return }
        micWatchInstalled = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let queue = DispatchQueue.main
        AudioObjectAddPropertyListenerBlock(system, &inputAddress, queue) { [weak self] _, _ in
            self?.pinBuiltInMicrophone()
        }
        AudioObjectAddPropertyListenerBlock(system, &devicesAddress, queue) { [weak self] _, _ in
            self?.pinBuiltInMicrophone()
        }
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pinBuiltInMicrophone()
        }
    }

    @discardableResult
    private func pinBuiltInMicrophone() -> String? {
        guard let device = macBookMicrophoneID() else {
            log("no built-in microphone found")
            return nil
        }
        let name = audioDeviceName(device)
        if defaultInputDevice() == device {
            return name
        }
        var id = device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &id
        )
        if status != noErr {
            log("couldn't switch system microphone to \(name): \(status)")
            return nil
        }
        log("system microphone set to \(name)")
        return name
    }

    private func defaultInputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return 0
        }
        return device
    }

    private func macBookMicrophoneID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }
        var builtin: AudioDeviceID?
        for device in devices {
            guard inputChannelCount(device) > 0 else { continue }
            guard transportType(device) == kAudioDeviceTransportTypeBuiltIn else { continue }
            let name = audioDeviceName(device)
            if name.localizedCaseInsensitiveContains("MacBook") {
                return device
            }
            builtin = builtin ?? device
        }
        return builtin
    }

    private func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        var channels = Int(list.pointee.mNumberBuffers)
        if channels == 0 { return 0 }
        // A buffer list's first buffer is enough to know the device can capture.
        return max(channels, 1)
    }

    private func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return 0
        }
        return transport
    }

    private func audioDeviceName(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else {
            return "Microphone"
        }
        return (name?.takeRetainedValue() as String?) ?? "Microphone"
    }

    private struct WorkerLayout {
        let python: URL
        let script: URL
        let model: URL
        let pythonPath: String?
    }

    private func workerLayout() -> WorkerLayout? {
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        let runtime = root.appendingPathComponent("Runtime")
        let bundledPython = runtime.appendingPathComponent("Python.framework/Versions/3.14/bin/python3.14")
        if FileManager.default.isExecutableFile(atPath: bundledPython.path) {
            return WorkerLayout(
                python: bundledPython,
                script: runtime.appendingPathComponent("dictate_server.py"),
                model: runtime.appendingPathComponent("models/cohere-transcribe-4bit"),
                pythonPath: runtime.appendingPathComponent("site-packages").path
            )
        }
        let python = root.appendingPathComponent(".venv-cohere/bin/python")
        let script = root.appendingPathComponent("dictate_server.py")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
        return WorkerLayout(
            python: python,
            script: script,
            model: root.appendingPathComponent("models/cohere-transcribe-4bit"),
            pythonPath: nil
        )
    }

    // MARK: Worker

    private func startWorker() {
        ensureVocabulary()
        guard let layout = workerLayout() else {
            statusMenuItem.title = "Python environment is missing"
            log("python environment is missing")
            return
        }

        let process = Process()
        process.executableURL = layout.python
        process.arguments = ["-u", layout.script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        if let pythonPath = layout.pythonPath {
            environment["PYTHONPATH"] = pythonPath
        }
        environment["COHERE_MODEL"] = layout.model.path
        environment["COHERE_VOCABULARY"] = supportDirectory().appendingPathComponent("vocabulary.txt").path
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.workerStopped(status: process.terminationStatus)
            }
        }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.consume(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            log(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        do {
            try process.run()
        } catch {
            statusMenuItem.title = "Couldn't start Cohere"
            log("worker failed: \(error.localizedDescription)")
            return
        }
        worker = process
        workerIn = input.fileHandleForWriting
        statusMenuItem.title = "Starting…"
        setSymbol("waveform")
        log("worker started")
    }

    private func workerStopped(status: Int32) {
        modelReady = false
        worker = nil
        workerIn = nil
        guard !quitting else { return }
        workerRestarts += 1
        if workerRestarts > 3 {
            statusMenuItem.title = "Cohere stopped"
            setSymbol("mic.slash")
            showTransient("Cohere stopped")
            log("worker exit \(status)")
            return
        }
        log("worker exit \(status), restarting")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.quitting, self.worker == nil else { return }
            self.startWorker()
        }
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 10) {
            let chunk = lineBuffer.prefix(upTo: newline)
            lineBuffer.removeSubrange(...newline)
            guard let line = String(data: chunk, encoding: .utf8), !line.isEmpty else { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("bad worker line: \(line)")
            return
        }
        if object["ready"] as? Bool == true {
            modelReady = true
            workerRestarts = 0
            if !recording && queue.isEmpty && !requestInFlight {
                statusMenuItem.title = "Ready"
                setSymbol("mic")
            }
            log("worker ready")
            showHintIfNeeded()
            pump()
            return
        }
        if object["loaded"] != nil, object["text"] == nil, object["error"] == nil {
            log(object["loaded"] as? Bool == true ? "model loaded" : "model unloaded")
            return
        }
        requestInFlight = false
        if let error = object["error"] as? String {
            log("transcribe error: \(error)")
            discardQueuedResult()
        } else {
            deliver(object["text"] as? String ?? "")
        }
        pump()
    }

    private var handlers: [((String?) -> Void)?] = []

    private func enqueue(_ url: URL, handler: ((String?) -> Void)? = nil) {
        queue.append(url)
        handlers.append(handler)
        pump()
    }

    private func pump() {
        guard modelReady, !requestInFlight, !queue.isEmpty, let input = workerIn else { return }
        let url = queue.removeFirst()
        let handler = handlers.isEmpty ? nil : handlers.removeFirst()
        requestInFlight = true
        let body = try? JSONSerialization.data(withJSONObject: ["wav": url.path])
        guard var body else { return }
        body.append(10)
        input.write(body)
        pendingPaste.append { [weak self] text in
            if let handler {
                handler(text)
            } else {
                self?.finishSingle(text, url: url)
            }
            self?.finishRequest()
        }
    }

    private func finishSingle(_ text: String?, url: URL) {
        guard let text else {
            storeTranscript(nil, for: url)
            showTransient("Saved the recording")
            statusMenuItem.title = modelReady ? "Ready" : "Loading Cohere…"
            setSymbol(modelReady ? "mic" : "waveform")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showTransient("Didn't catch that")
            statusMenuItem.title = modelReady ? "Ready" : "Loading Cohere…"
            setSymbol("mic")
            return
        }
        storeTranscript(trimmed, for: url)
        lastTranscript = trimmed
        copyLastItem?.isEnabled = true
        hud.hide()
        paste(trimmed)
        if !recording {
            statusMenuItem.title = "Ready"
            setSymbol("mic", title: "")
        }
    }

    private func discardQueuedResult() {
        let completion = pendingPaste.isEmpty ? nil : pendingPaste.removeFirst()
        completion?(nil)
        if !recording && partsExpected == 0 {
            statusMenuItem.title = modelReady ? "Ready" : "Loading Cohere…"
            setSymbol(modelReady ? "mic" : "waveform")
        }
    }

    private func deliver(_ text: String) {
        let completion = pendingPaste.isEmpty ? nil : pendingPaste.removeFirst()
        completion?(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func finishRequest() {
        if !recording && queue.isEmpty && !requestInFlight {
            statusMenuItem.title = modelReady ? "Ready" : "Loading Cohere…"
        }
    }

    // MARK: Recordings

    private func supportDirectory() -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Parakeet Dictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recordingsDirectory() -> URL {
        let url = supportDirectory().appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func ensureVocabulary() {
        let url = supportDirectory().appendingPathComponent("vocabulary.txt")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let seed = """
        # One term per line. If those words show up, they keep this spelling.
        # A line like "heard phrase -> Snapdragon 8 Elite Gen 5" replaces that phrase.
        Snapdragon 8 Elite Gen 5
        Qualcomm
        Adreno

        """
        try? seed.write(to: url, atomically: true, encoding: .utf8)
    }

    private func storeTranscript(_ text: String?, for wav: URL) {
        let stem = wav.deletingPathExtension()
        let transcript = stem.appendingPathExtension("txt")
        let failure = stem.appendingPathExtension("err")
        if let text, !text.isEmpty {
            try? text.write(to: transcript, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: failure)
        } else {
            try? "failed\n".write(to: failure, atomically: true, encoding: .utf8)
        }
        pruneRecordings()
    }

    private func recordingFiles() -> [URL] {
        let folder = recordingsDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
    }

    private func pruneRecordings() {
        let extra = recordingFiles().dropFirst(recordingLimit)
        for wav in extra {
            let stem = wav.deletingPathExtension()
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: stem.appendingPathExtension("txt"))
            try? FileManager.default.removeItem(at: stem.appendingPathExtension("err"))
        }
    }

    private func recordingTitle(_ wav: URL) -> String {
        let name = wav.deletingPathExtension().lastPathComponent
        let transcript = wav.deletingPathExtension().appendingPathExtension("txt")
        let failure = wav.deletingPathExtension().appendingPathExtension("err")
        if let text = try? String(contentsOf: transcript, encoding: .utf8) {
            let snippet = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if !snippet.isEmpty {
                let short = snippet.count > 42 ? String(snippet.prefix(42)) + "…" : snippet
                return "\(name) — \(short)"
            }
        }
        if FileManager.default.fileExists(atPath: failure.path) {
            return "\(name) — failed"
        }
        return name
    }

    private func rebuildRecordingsMenu() {
        let submenu = recordingsItem.submenu ?? NSMenu(title: "Recordings")
        recordingsItem.submenu = submenu
        submenu.removeAllItems()
        let open = item("Open Recordings Folder", #selector(openRecordingsFolder))
        submenu.addItem(open)
        submenu.addItem(.separator())
        let files = recordingFiles()
        if files.isEmpty {
            let empty = NSMenuItem(title: "No recordings yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }
        for wav in files.prefix(12) {
            let parent = NSMenuItem(title: recordingTitle(wav), action: nil, keyEquivalent: "")
            let actions = NSMenu()
            let retry = item("Retry transcription", #selector(retryRecording(_:)))
            retry.representedObject = wav.path
            let reveal = item("Show in Finder", #selector(revealRecording(_:)))
            reveal.representedObject = wav.path
            let download = item("Copy to Downloads", #selector(copyRecordingToDownloads(_:)))
            download.representedObject = wav.path
            actions.addItem(retry)
            actions.addItem(reveal)
            actions.addItem(download)
            parent.submenu = actions
            submenu.addItem(parent)
        }
    }

    @objc private func openRecordingsFolder() {
        NSWorkspace.shared.open(recordingsDirectory())
    }

    @objc private func editVocabulary() {
        ensureVocabulary()
        NSWorkspace.shared.open(supportDirectory().appendingPathComponent("vocabulary.txt"))
    }

    @objc private func retryRecording(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        hud.show("…", symbol: "waveform", tint: .white)
        statusMenuItem.title = "Transcribing…"
        enqueue(url)
    }

    @objc private func revealRecording(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func copyRecordingToDownloads(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let source = URL(fileURLWithPath: path)
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        var destination = downloads.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let stem = source.deletingPathExtension().lastPathComponent
            destination = downloads.appendingPathComponent("\(stem)-\(String(UUID().uuidString.prefix(4))).wav")
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            log("copy failed: \(error.localizedDescription)")
            showTransient("Couldn't copy the recording")
        }
    }

    // MARK: Paste

    @discardableResult
    private func paste(_ text: String) -> Bool {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            var kept = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    kept = true
                }
            }
            return kept ? copy : nil
        } ?? []

        board.clearContents()
        board.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(30_000)
        up?.post(tap: .cghidEventTap)
        log("typed \(text.count) characters")

        if AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                board.clearContents()
                if !saved.isEmpty {
                    board.writeObjects(saved)
                }
            }
        }
        return true
    }

    // MARK: Permissions and tap

    private func promptForPermissions() {
        let trusted = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
        if !trusted {
            statusMenuItem.title = "Allow Parakeet in Accessibility"
            log("accessibility not granted")
        }
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    log(granted ? "microphone granted" : "microphone denied")
                }
            }
        default:
            statusMenuItem.title = "Allow Parakeet in Microphone"
            log("microphone denied")
        }
    }

    private func installTap() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                let flags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
                let keyDown = event.type == .keyDown
                let keyCode = Int64(event.keyCode)
                self?.handle(flags: flags, keyDown: keyDown, keyCode: keyCode)
            }
            log(globalMonitor == nil ? "global monitor denied" : "global monitor installed")
        }
        if tap != nil { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: pointer
        ) else {
            statusMenuItem.title = "Allow Parakeet in Accessibility"
            setSymbol("mic.slash", title: "")
            log("event tap denied")
            return
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        log("event tap installed")
    }

    private func refreshAccess() {
        let trusted = AXIsProcessTrusted()
        let previousWasBlocked = accessReady == false
        guard trusted != accessReady else { return }
        accessReady = trusted
        log("accessibility \(trusted)")
        if trusted && previousWasBlocked {
            log("accessibility granted, restarting so text can be typed in")
            restart()
        }
    }

    @objc private func recheckPermissions() {
        promptForPermissions()
        installTap()
        if tap == nil {
            openPrivacy("Accessibility")
        }
    }

    @objc private func openAccessibility() { openPrivacy("Accessibility") }
    @objc private func openInputMonitoring() { openPrivacy("ListenEvent") }
    @objc private func openMicrophone() { openPrivacy("Microphone") }

    private func openPrivacy(_ anchor: String) {
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_\(anchor)"
        let legacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_\(anchor)"
        if let url = URL(string: modern), NSWorkspace.shared.open(url) {
            return
        }
        if let url = URL(string: legacy) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menu and HUD

    private func buildMenu() {
        menu.delegate = self
        statusMenuItem.isEnabled = false
        hintMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(hintMenuItem)
        menu.addItem(.separator())
        menu.addItem(item("Listen for 5 seconds", #selector(listenBriefly)))
        let copy = item("Copy Last Text", #selector(copyLastText))
        copy.isEnabled = false
        copyLastItem = copy
        menu.addItem(copy)
        recordingsItem.submenu = NSMenu(title: "Recordings")
        menu.addItem(recordingsItem)
        menu.addItem(item("Edit vocabulary…", #selector(editVocabulary)))
        menu.addItem(.separator())
        menu.addItem(item("Recheck permissions", #selector(recheckPermissions)))
        menu.addItem(item("Restart Parakeet", #selector(restart)))
        menu.addItem(item("Accessibility settings…", #selector(openAccessibility)))
        menu.addItem(item("Input Monitoring settings…", #selector(openInputMonitoring)))
        menu.addItem(item("Microphone settings…", #selector(openMicrophone)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Parakeet", #selector(quit)))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        if recording {
            statusMenuItem.title = "Listening…"
        } else if requestInFlight {
            statusMenuItem.title = "Transcribing…"
        } else if !AXIsProcessTrusted() {
            statusMenuItem.title = "Allow Parakeet in Accessibility and Input Monitoring"
        } else if !modelReady {
            statusMenuItem.title = "Loading Cohere…"
        } else {
            statusMenuItem.title = "Ready"
        }
        copyLastItem?.isEnabled = !(lastTranscript ?? "").isEmpty
        rebuildRecordingsMenu()
    }

    @objc private func copyLastText() {
        guard let lastTranscript, !lastTranscript.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(lastTranscript, forType: .string)
        hud.show("Copied", symbol: "doc.on.clipboard", tint: .white)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, !self.recording, !self.requestInFlight else { return }
            self.hud.hide()
        }
    }

    private func setSymbol(_ name: String, tint: NSColor? = nil, title: String? = nil) {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Parakeet Dictation")
        image?.isTemplate = tint == nil
        button.image = image
        if let title {
            button.title = title
        }
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeft
        button.contentTintColor = tint
    }

    @objc private func listenBriefly() {
        guard !recording else { return }
        beginCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.stopCapture(transcribe: true)
        }
    }

    private func showTransient(_ text: String) {
        hud.show(text, symbol: "exclamationmark.circle", tint: .systemOrange)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.recording, !self.requestInFlight else { return }
            self.hud.hide()
        }
    }

    private func showHintIfNeeded() {}

    @objc private func restart() {
        if instanceLock >= 0 {
            flock(instanceLock, LOCK_UN)
            close(instanceLock)
            instanceLock = -1
        }
        NSWorkspace.shared.open(Bundle.main.bundleURL)
        shutdown()
        exit(0)
    }

    @objc private func quit() {
        shutdown()
        NSApp.terminate(nil)
    }
}

final class DictationHUD: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let effect = NSVisualEffectView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 26),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .utilityWindow

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 13
        effect.layer?.masksToBounds = true
        contentView = effect

        icon.imageScaling = .scaleProportionallyUpOrDown
        effect.addSubview(icon)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .left
        label.lineBreakMode = .byClipping
        effect.addSubview(label)
    }

    func show(_ text: String, symbol: String, tint: NSColor) {
        label.stringValue = text
        label.sizeToFit()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        let height: CGFloat = 26
        let width = 8 + 14 + 6 + label.frame.width + 10
        setContentSize(NSSize(width: width, height: height))
        effect.frame = NSRect(x: 0, y: 0, width: width, height: height)
        effect.layer?.cornerRadius = height / 2
        icon.frame = NSRect(x: 8, y: 6, width: 14, height: 14)
        label.frame = NSRect(x: 26, y: 4, width: label.frame.width + 2, height: 18)
        place()
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 64))
    }
}

private func resample(_ input: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
    guard !input.isEmpty else { return [] }
    if abs(inputRate - outputRate) < 1 { return input }
    let ratio = inputRate / outputRate
    let count = Int(Double(input.count) / ratio)
    guard count > 1 else { return input }
    var output = [Float](repeating: 0, count: count)
    for index in 0..<count {
        let position = Double(index) * ratio
        let left = Int(position)
        let right = min(left + 1, input.count - 1)
        let fraction = Float(position - Double(left))
        output[index] = input[left] * (1 - fraction) + input[right] * fraction
    }
    return output
}

private func writeWav(_ samples: [Float], rate: Int, to url: URL) throws {
    var data = Data(capacity: 44 + samples.count * 2)
    func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
    func le32(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    func le16(_ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    ascii("RIFF")
    le32(UInt32(36 + samples.count * 2))
    ascii("WAVE")
    ascii("fmt ")
    le32(16)
    le16(1)
    le16(1)
    le32(UInt32(rate))
    le32(UInt32(rate * 2))
    le16(2)
    le16(16)
    ascii("data")
    le32(UInt32(samples.count * 2))
    for sample in samples {
        let clamped = max(-1 as Float, min(1, sample))
        le16(UInt16(bitPattern: Int16(clamped * 32767)))
    }
    try data.write(to: url, options: .atomic)
}

private func log(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ParakeetDictation.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

private var instanceLock: Int32 = -1

private func alreadyRunning() -> Bool {
    let fd = open("/tmp/parakeet-dictation.lock", O_CREAT | O_RDWR, 0o644)
    if fd < 0 { return false }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        return true
    }
    instanceLock = fd
    return false
}

if alreadyRunning() {
    fputs("Parakeet Dictation is already running.\n", stderr)
    exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
private let delegate = AppDelegate()
application.delegate = delegate
application.run()

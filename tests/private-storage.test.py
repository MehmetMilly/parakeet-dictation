#!/usr/bin/env python3
"""Compile the app's actual storage helper without starting the dictation app."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'DictationApp.swift').read_text()
helper = source.split('// MARK: Private storage\n', 1)[1]
checks = r'''
let fm = FileManager.default
let root = PrivateStorage.temporaryDirectory.appendingPathComponent("parakeet-storage-test-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
func mode(_ url: URL) throws -> Int {
    (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
}
func check(_ condition: Bool, _ name: String) {
    guard condition else { fatalError("FAIL: \(name)") }
    print("PASS: \(name)")
}
umask(0)
let recordings = root.appendingPathComponent("support/Recordings")
try PrivateStorage.prepareDirectory(recordings)
check(try mode(recordings) == 0o700, "directory mode 0700 under umask 000")
let wav = recordings.appendingPathComponent("take.wav")
try PrivateStorage.write(Data([1, 2, 3]), to: wav)
check(try mode(wav) == 0o600, "audio mode 0600 under umask 000")
check(try Data(contentsOf: wav) == Data([1, 2, 3]), "audio bytes preserved")
let transcript = recordings.appendingPathComponent("take.txt")
try PrivateStorage.write("private transcript", to: transcript)
check(try mode(transcript) == 0o600, "transcript mode 0600")
try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wav.path)
try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: transcript.path)
try PrivateStorage.restrictExistingRecordings(in: recordings)
check(try mode(wav) == 0o600 && mode(transcript) == 0o600, "existing audio/transcript permissions repaired")
try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordings.path)
try PrivateStorage.prepareDirectory(recordings)
check(try mode(recordings) == 0o700, "existing directory permissions repaired")
let victim = root.appendingPathComponent("victim.txt")
try "unchanged".write(to: victim, atomically: true, encoding: .utf8)
try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: victim.path)
let linked = recordings.appendingPathComponent("linked.txt")
try fm.createSymbolicLink(at: linked, withDestinationURL: victim)
try PrivateStorage.restrictExistingRecordings(in: recordings)
check(try mode(victim) == 0o644, "migration does not chmod symlink target")
try PrivateStorage.write("replacement", to: linked)
check(try String(contentsOf: victim, encoding: .utf8) == "unchanged", "atomic write leaves symlink target unchanged")
check(try String(contentsOf: linked, encoding: .utf8) == "replacement" && mode(linked) == 0o600, "atomic write replaces symlink itself privately")
let hardlink = recordings.appendingPathComponent("hard.txt")
try fm.linkItem(at: victim, to: hardlink)
try PrivateStorage.restrictExistingRecordings(in: recordings)
check(try mode(victim) == 0o644, "migration does not chmod hard-linked target")
let directoryLink = root.appendingPathComponent("directory-link")
try fm.createSymbolicLink(at: directoryLink, withDestinationURL: recordings)
var rejected = false
do { try PrivateStorage.write("no", to: directoryLink.appendingPathComponent("reject.txt")) } catch { rejected = true }
check(rejected && !fm.fileExists(atPath: recordings.appendingPathComponent("reject.txt").path), "symlink directory path rejected")
let empty = recordings.appendingPathComponent("empty.err")
try PrivateStorage.write(Data(), to: empty)
check(try mode(empty) == 0o600 && Data(contentsOf: empty).isEmpty, "empty data safely written")
check(try fm.contentsOfDirectory(atPath: recordings.path).allSatisfy { !$0.hasPrefix(".parakeet-") }, "no atomic temporary files remain")
'''
with tempfile.TemporaryDirectory(prefix='parakeet-swift-tests-') as temporary:
    main = Path(temporary) / 'main.swift'
    main.write_text('import Foundation\nimport Darwin\n' + helper + '\n' + checks)
    subprocess.run(['swift', str(main)], check=True)

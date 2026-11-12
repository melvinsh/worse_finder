//
//  Diagnostics.swift
//  worse_finder
//
//  On-device inspection. Run with --walkie.
//

import Foundation
import Darwin

enum Diagnostics {
    static let bundleID = "com.corentinlarroque.walkie-talkie"

    static func runExportCheck() {
        guard let group = wq_app_group() else { print("[export-check] no group"); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-check", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Every container holds at least its metadata plist, so the empty case
        // is the fixture's empty directory.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let empty = documents.appendingPathComponent("empty-folder").path
        let nested = documents.path
        let big = wq_ls_container("com.apple.mobilesafari") ?? ""

        let cases: [(String, String)] = [
            ("empty", empty),
            ("nested", nested),
            ("big", big),
        ]

        for (label, path) in cases {
            guard !path.isEmpty else { print("[export-check] \(label): no container"); continue }
            let started = Date()
            var progressCalls = 0
            do {
                let result = try Exporter().run(container: path, name: label, outputDirectory: directory) { _, _ in
                    progressCalls += 1
                }
                let archive = (try? FileManager.default.attributesOfItem(atPath: result.url.path))?[.size] as? Int64 ?? 0
                let central = zipCentral(result.url.path)
                print("[export-check] \(label) files=\(result.files) bytes=\(result.bytes) skipped=\(result.skipped) archive=\(archive) entries=\(central.entries) eocd=\(central.ok) progress=\(progressCalls) seconds=\(String(format: "%.1f", Date().timeIntervalSince(started)))")
            } catch {
                print("[export-check] \(label) FAILED \(error.localizedDescription)")
            }
        }

        // Cancel must abort the export and leave nothing behind.
        let exporter = Exporter()
        var outcome = "no callback"
        var leftover = false
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try exporter.run(container: big, name: "cancel", outputDirectory: directory) { _, _ in
                    exporter.cancel()
                }
                outcome = "completed unexpectedly files=\(result.files)"
            } catch {
                outcome = error.localizedDescription
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 120)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        leftover = files.contains { $0.hasPrefix("cancel-") }
        print("[export-check] cancel: \(outcome) leftover=\(leftover)")

        // Progress must fire for a large container.
        var calls = 0
        _ = try? Exporter().run(container: big, name: "progress", outputDirectory: directory) { _, _ in calls += 1 }
        print("[export-check] progress callbacks=\(calls)")
        print("[export-check] done")
    }

    static func runWalkie() {
        guard let group = wq_app_group() else {
            print("[walkie] no App Group")
            return
        }
        print("[walkie] app group \(group)")

        let store = Store.loadStore(group: group)
        let mapped = (store?["containers"] as? [String: String]) ?? [:]
        let layout = (store?["layout"] as? String) ?? "none"
        let fromStore = mapped.filter { $0.value == bundleID }.map(\.key).sorted()
        print("[walkie] store layout \(layout): \(mapped.count) containers, \(fromStore.count) for this bundle")

        let scanned = Set(wq_pathleak("/private/var/mobile/Containers/Data/Application", 8_000_000) ?? [])
        print("[walkie] pathleak sees \(scanned.count) containers")

        // Containers the scan finds but the store does not list: identify by prefs.
        var fromPrefs: [String] = []
        for container in scanned.sorted() where !fromStore.contains(container) {
            let handle = wq_grant(container, group, false)
            guard handle >= 0 else { continue }
            let prefs = (try? FileManager.default.contentsOfDirectory(atPath: container + "/Library/Preferences")) ?? []
            let match = prefs.contains { $0.lowercased().contains("walkie") }
            wq_release(handle)
            if match { fromPrefs.append(container) }
        }
        print("[walkie] extra containers identified by prefs: \(fromPrefs.count)")

        for container in fromStore {
            report(container, group: group, origin: "store")
        }
        for container in fromPrefs {
            report(container, group: group, origin: "prefs")
        }

        let groups = wq_ls_group_containers(bundleID) ?? [:]
        print("[walkie] app groups reported by LS: \(groups.count)")
        for (identifier, path) in groups.sorted(by: { $0.key < $1.key }) {
            print("[walkie]   group \(identifier)")
            report(path, group: group, origin: "group")
        }

        print("[walkie] done")
    }

    /// Reads the end-of-central-directory record: proves the archive is closed
    /// and tells us how many entries the writer recorded.
    private static func zipCentral(_ path: String) -> (ok: Bool, entries: Int) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count >= 22 else {
            return (false, 0)
        }
        let tail = [UInt8](data.suffix(22))
        guard tail[0] == 0x50, tail[1] == 0x4b, tail[2] == 0x05, tail[3] == 0x06 else { return (false, 0) }
        let entries = Int(tail[10]) | Int(tail[11]) << 8
        return (true, entries)
    }

    private static func report(_ path: String, group: String, origin: String) {
        let exists = FileManager.default.fileExists(atPath: path)
        var size: Int64 = -1
        var files = -1
        var modified = "-"

        if exists {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               let date = attributes[.modificationDate] as? Date {
                modified = ISO8601DateFormatter().string(from: date)
            }
            let handle = wq_grant(path, group, false)
            if handle >= 0 {
                (size, files) = walk(path)
                wq_release(handle)
            } else {
                print("[walkie] \(origin) \(path) exists but grant=\(handle): \(wq_last_error() ?? "")")
            }
        }

        print("[walkie] \(origin) \(path)")
        print("[walkie]    exists=\(exists) bytes=\(size) files=\(files) modified=\(modified)")
    }

    private static func walk(_ root: String) -> (Int64, Int) {
        var bytes: Int64 = 0
        var files = 0
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }) else { return (0, 0) }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            bytes += Int64(values?.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }
}

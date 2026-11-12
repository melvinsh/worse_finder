//
//  Store.swift
//  worse_finder
//
//  App discovery: pathleak for containers, lsd's CSStore for bundle IDs,
//  LaunchServices for names and icons. Plus ZIP export.
//

import Foundation
import SwiftUI
import UIKit

struct GroupContainer: Codable, Hashable, Identifiable {
    let identifier: String
    let path: String
    var id: String { identifier }
}

struct AppEntry: Identifiable, Codable, Hashable {
    let container: String
    var bundleID: String?
    var name: String?
    var isSystem: Bool = false
    var alternates: [String] = []
    var groups: [GroupContainer] = []

    var id: String { container }

    var displayName: String {
        if let name, let cleaned = AppEntry.sanitize(name) { return cleaned }
        if let bundleID, !bundleID.isEmpty { return bundleID }
        return String(container.split(separator: "/").last ?? "unknown")
    }

    var subtitle: String {
        if let bundleID, !bundleID.isEmpty, bundleID != displayName { return bundleID }
        return String(container.split(separator: "/").last ?? "")
    }

    /// Names coming out of the store can be whitespace or formatting marks.
    static func sanitize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return trimmed
    }

    var tint: Color {
        let seed = abs((bundleID ?? container).hashValue) % 6
        return [Color.blue, .purple, .pink, .orange, .green, .teal][seed]
    }

    var initials: String {
        let words = displayName.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

private let appsCacheKey = "worse_finder.apps.v5"

final class Store: ObservableObject {
    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var scanning = false
    @Published private(set) var status = ""

    private let queue = DispatchQueue(label: "worse_finder.scan", qos: .userInitiated)
    private let appParent = "/private/var/mobile/Containers/Data/Application"
    private let daemonParent = "/private/var/mobile/Containers/Data/InternalDaemon"

    init() {
        if let data = UserDefaults.standard.data(forKey: appsCacheKey),
           let cached = try? JSONDecoder().decode([AppEntry].self, from: data) {
            apps = cached
            status = "\(cached.count) apps (cached)"
        }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        status = "scanning containers…"

        queue.async {
            let started = Date()
            guard let group = wq_app_group() else {
                self.finish("no App Group — the app was signed without one")
                return
            }

            self.setStatus("pathleak: enumerating containers…")
            let limit = min(max(wq_baseline_inode(), 200_000), 8_000_000)
            let scanned = Set(wq_pathleak(self.appParent, limit) ?? [])

            self.setStatus("reading the LaunchServices store…")
            let store = Store.loadStore(group: group)
            let mapped = (store?["containers"] as? [String: String]) ?? [:]
            let storeNames = (store?["names"] as? [String: String]) ?? [:]
            let layout = (store?["layout"] as? String) ?? "none"
            self.setStatus("store \(layout): \(mapped.count) containers")

            var containers = Set(mapped.keys)
            containers.formUnion(scanned)

            var entries: [AppEntry] = []
            var resolved: [String: String] = [:]

            for container in containers {
                var bundleID = mapped[container]
                if bundleID == nil {
                    bundleID = self.identifierFromFilesystem(container, group: group)
                }

                var name: String?
                var system = false
                var groups: [GroupContainer] = []
                if let bundleID {
                    let type = wq_ls_application_type(bundleID)
                    system = type == 1 || type == 2 || bundleID.hasPrefix("com.apple.")
                    groups = (wq_ls_group_containers(bundleID) ?? [:])
                        .filter { FileManager.default.fileExists(atPath: $0.value) }
                        .map { GroupContainer(identifier: $0.key, path: $0.value) }
                        .sorted { $0.identifier < $1.identifier }
                } else {
                    system = true   // unidentified containers are never user apps
                }
                if let bundleID {
                    if let cached = resolved[bundleID] {
                        name = cached.isEmpty ? nil : cached
                    } else {
                        name = Self.clean(wq_ls_name(bundleID)) ?? Self.clean(storeNames[bundleID])
                        resolved[bundleID] = name ?? ""
                    }
                }

                entries.append(AppEntry(container: container, bundleID: bundleID,
                                        name: name, isSystem: system, groups: groups))
            }

            // Containers of earlier installs stay in the store after the folder
            // is gone; and one bundle can own several live containers. Drop the
            // dead ones, keep one primary per bundle and the rest reachable.
            var live: [AppEntry] = []
            var dead = 0
            for entry in entries {
                var info = stat()
                if lstat(entry.container, &info) != 0 && errno == ENOENT {
                    dead += 1
                    continue
                }
                live.append(entry)
            }

            var byBundle: [String: AppEntry] = [:]
            var extras: [String: [String]] = [:]
            var anonymous: [AppEntry] = []

            for entry in live {
                guard let bundleID = entry.bundleID else {
                    anonymous.append(entry)
                    continue
                }
                guard var current = byBundle[bundleID] else {
                    byBundle[bundleID] = entry
                    continue
                }
                let winner = Store.preferred(entry, current, bundleID: bundleID, group: group)
                if winner.container == entry.container {
                    extras[bundleID, default: []].append(current.container)
                    current = entry
                } else {
                    extras[bundleID, default: []].append(entry.container)
                }
                byBundle[bundleID] = current
            }

            entries = byBundle.values.map { entry in
                var copy = entry
                copy.alternates = (extras[entry.bundleID ?? ""] ?? []).sorted()
                return copy
            } + anonymous

            if dead > 0 { print("[scan] dropped \(dead) containers that no longer exist") }
            let merged = extras.values.reduce(0) { $0 + $1.count }
            if merged > 0 { print("[scan] \(merged) extra live containers kept as alternates") }

            entries.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

            let named = entries.filter { $0.name != nil }.count
            let systemCount = entries.filter { $0.isSystem }.count
            let groupCount = entries.reduce(0) { $0 + $1.groups.count }
            let appsWithGroups = entries.filter { !$0.groups.isEmpty }.count
            let identified = entries.filter { $0.bundleID != nil }.count
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            print("[scan] \(entries.count) apps, \(identified) identified, \(named) named, \(systemCount) system, \(appsWithGroups) apps with \(groupCount) app groups, layout \(layout), \(elapsed)s")

            self.publish(entries, status: "\(entries.count - systemCount) apps · \(systemCount) system · \(elapsed)s")
        }
    }

    /// LaunchServices' own answer wins; otherwise the container with more data.
    private static func preferred(_ candidate: AppEntry, _ current: AppEntry,
                                  bundleID: String, group: String) -> AppEntry {
        if let reported = wq_ls_container(bundleID) {
            if candidate.container == reported { return candidate }
            if current.container == reported { return current }
        }
        let candidateWeight = weigh(candidate.container, group: group)
        let currentWeight = weigh(current.container, group: group)
        return candidateWeight > currentWeight ? candidate : current
    }

    /// Rough size signal, capped so a huge container cannot stall a scan.
    private static func weigh(_ path: String, group: String) -> Int64 {
        let handle = wq_grant(path, group, false)
        guard handle >= 0 else { return -1 }
        defer { wq_release(handle) }

        var score: Int64 = 0
        var seen = 0
        if let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }) {
            for case let url as URL in enumerator {
                seen += 1
                if seen > 4000 { break }
                var info = stat()
                guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                score += 1 + Int64(info.st_size) / 4096
            }
        }
        return score
    }

    private static func clean(_ value: String?) -> String? {
        value.flatMap(AppEntry.sanitize)
    }

    // MARK: - LaunchServices store

    static func loadStore(group: String) -> [String: Any]? {
        let daemons = wq_pathleak("/private/var/mobile/Containers/Data/InternalDaemon", 400_000) ?? []
        var best: [String: Any]?
        var bestCount = 0

        for daemon in daemons {
            let handle = wq_grant(daemon, group, false)
            guard handle >= 0 else { continue }
            defer { wq_release(handle) }

            for sub in ["Library/Caches", "Library", ""] {
                let directory = sub.isEmpty ? daemon : daemon + "/" + sub
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
                for name in names where name.hasSuffix(".csstore") {
                    let path = directory + "/" + name
                    guard wq_ls_store_candidate(path) else { continue }
                    guard let parsed = wq_ls_parse_store(path) else { continue }
                    let count = (parsed["containers"] as? [String: String])?.count ?? 0
                    if count > bestCount {
                        bestCount = count
                        best = parsed
                        print("[scan] store \(path) layout \(parsed["layout"] ?? "?") \(count) containers")
                    }
                }
            }
        }
        return best
    }

    private func identifierFromFilesystem(_ container: String, group: String) -> String? {
        let handle = wq_grant(container, group, false)
        guard handle >= 0 else { return nil }
        defer { wq_release(handle) }

        if let identifier = wq_container_identifier(container) { return identifier }

        let prefs = container + "/Library/Preferences"
        if let hit = ((try? FileManager.default.contentsOfDirectory(atPath: prefs)) ?? [])
            .first(where: { $0.hasSuffix(".plist") }) {
            return String(hit.dropLast(6))
        }
        let saved = container + "/Library/Saved Application State"
        if let hit = ((try? FileManager.default.contentsOfDirectory(atPath: saved)) ?? [])
            .first(where: { $0.hasSuffix(".savedState") }) {
            return String(hit.dropLast(11))
        }
        return nil
    }

    func clearCache() {
        UserDefaults.standard.removeObject(forKey: appsCacheKey)
        DispatchQueue.main.async {
            self.apps = []
            self.status = ""
        }
    }

    // MARK: - sizes

    func measure(_ entry: AppEntry, completion: @escaping (Int64, Int) -> Void) {
        queue.async {
            guard let group = wq_app_group() else { completion(0, 0); return }
            let handle = wq_grant(entry.container, group, false)
            guard handle >= 0 else { completion(0, 0); return }
            defer { wq_release(handle) }

            var bytes: Int64 = 0
            var files = 0
            let root = URL(fileURLWithPath: entry.container)
            if let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, _ in true }) {
                for case let url as URL in enumerator {
                    var info = stat()
                    guard lstat(url.path, &info) == 0 else { continue }
                    guard (info.st_mode & S_IFMT) == S_IFREG else { continue }
                    bytes += Int64(info.st_size)
                    files += 1
                }
            }
            DispatchQueue.main.async { completion(bytes, files) }
        }
    }

    // MARK: - plumbing

    private func setStatus(_ text: String) {
        print("[scan] " + text)
        DispatchQueue.main.async { self.status = text }
    }

    private func publish(_ entries: [AppEntry], status text: String) {
        DispatchQueue.main.async {
            self.apps = entries
            self.status = text
            self.scanning = false
            if let data = try? JSONEncoder().encode(entries) {
                UserDefaults.standard.set(data, forKey: appsCacheKey)
            }
        }
    }

    private func finish(_ message: String) {
        DispatchQueue.main.async {
            self.status = message
            self.scanning = false
        }
    }
}

// MARK: - icons

final class IconCache: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]
    private var loading: Set<String> = []
    private let queue = DispatchQueue(label: "worse_finder.icons", qos: .utility, attributes: .concurrent)

    func load(_ bundleID: String) {
        guard images[bundleID] == nil, !loading.contains(bundleID) else { return }
        loading.insert(bundleID)
        queue.async {
            let image = wq_app_icon(bundleID)
            DispatchQueue.main.async {
                self.loading.remove(bundleID)
                if let image { self.images[bundleID] = image }
            }
        }
    }
}

// MARK: - export

struct ExportResult {
    let url: URL
    let files: Int
    let bytes: Int64
    let skipped: Int
    let seconds: Double
}

enum ExportError: LocalizedError {
    case noGroup
    case noAccess(Int64, String)
    case cancelled
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noGroup: return "No App Group entitlement."
        case .noAccess(let code, let reason): return "Could not open the container (\(code)): \(reason)"
        case .cancelled: return "Export cancelled."
        case .writeFailed(let reason): return reason
        }
    }
}

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: value)
    }
    static func date(_ value: Date?) -> String {
        guard let value else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy HH:mm"
        return formatter.string(from: value)
    }
    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

final class Exporter {
    private(set) var cancelled = false
    func cancel() { cancelled = true }

    func run(container: String,
             name: String,
             outputDirectory: URL? = nil,
             progress: @escaping (Int, Int64) -> Void) throws -> ExportResult {
        guard let group = wq_app_group() else { throw ExportError.noGroup }

        let handle = wq_grant(container, group, false)
        guard handle >= 0 else {
            throw ExportError.noAccess(handle, wq_last_error() ?? "unknown")
        }
        defer { wq_release(handle) }

        let started = Date()
        let directory = outputDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safe = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = directory.appendingPathComponent("\(safe.isEmpty ? "container" : safe)-\(Fmt.stamp()).zip")

        guard let writer = ZipWriter(atPath: target.path) else {
            throw ExportError.writeFailed("Could not create the archive.")
        }
        var finished = false
        defer {
            if !finished { try? FileManager.default.removeItem(at: target) }
        }

        // Paths come back in both /var and /private/var form; normalise so the
        // prefix maths and the self-export guard actually match.
        func normalize(_ path: String) -> String {
            path.hasPrefix("/private/") ? String(path.dropFirst(8)) : path
        }
        let containerPath = normalize(container)
        let outputRoot = normalize(directory.path)
        let archivePath = normalize(target.path)

        let root = URL(fileURLWithPath: container)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }) else {
            throw ExportError.writeFailed("Could not read the container.")
        }

        var files = 0
        var bytes: Int64 = 0
        var skipped = 0
        var seen = 0

        for case let url as URL in enumerator {
            if cancelled { throw ExportError.cancelled }
            let resolved = normalize(url.path)
            // Never archive the archive: exporting our own container would
            // otherwise read a file that is still growing.
            if resolved == archivePath || resolved.hasPrefix(outputRoot + "/") { continue }
            if url.lastPathComponent == target.lastPathComponent { continue }

            var relative = resolved
            if relative.hasPrefix(containerPath) {
                relative = String(relative.dropFirst(containerPath.count))
            }
            relative = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
            guard !relative.isEmpty else { continue }

            // stat, not NSURL resource values: those come back nil for paths
            // that are only reachable through the sandbox extension.
            var info = stat()
            guard lstat(url.path, &info) == 0 else { skipped += 1; continue }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK { skipped += 1; continue }
            if kind == S_IFDIR {
                _ = writer.addDirectory(relative)
                continue
            }
            guard kind == S_IFREG else { skipped += 1; continue }

            // Only count what actually made it into the archive: a file the
            // sandbox refuses (the container metadata plist) must not inflate
            // the reported totals.
            if writer.addFile(url.path, entry: relative) {
                files += 1
                bytes += Int64(info.st_size)
            }

            seen += 1
            if seen % 20 == 0 {
                let snapshot = (files, bytes)
                DispatchQueue.main.async { progress(snapshot.0, snapshot.1) }
            }
        }

        guard writer.close() else {
            throw ExportError.writeFailed(writer.lastError ?? "Could not finish the archive.")
        }

        finished = true
        return ExportResult(url: target,
                            files: files,
                            bytes: bytes,
                            skipped: skipped + Int(writer.filesSkipped),
                            seconds: Date().timeIntervalSince(started))
    }
}

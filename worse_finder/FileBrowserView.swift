//
//  FileBrowserView.swift
//  worse_finder
//

import SwiftUI
import UIKit

struct FileItem: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let isBrokenLink: Bool
    let size: Int64
    let modified: Date?
    let linkTarget: String?

    var id: String { path }

    var icon: String {
        if isBrokenLink { return "link.badge.plus" }
        if isSymlink { return "link" }
        if isDirectory { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo"
        case "mov", "mp4", "m4v": return "film"
        case "mp3", "m4a", "wav", "aac", "caf": return "music.note"
        case "zip", "gz", "ipa", "7z": return "archivebox"
        case "plist": return "gearshape"
        case "sqlite", "db", "sqlite3": return "cylinder.split.1x2"
        case "swift", "m", "h", "c", "js", "json", "py", "sh": return "chevron.left.forwardslash.chevron.right"
        case "txt", "md", "log": return "doc.text"
        default: return "doc"
        }
    }

    var tint: Color {
        if isBrokenLink { return .secondary }
        if isSymlink { return .indigo }
        if isDirectory { return .blue }
        switch icon {
        case "photo": return .pink
        case "film": return .purple
        case "music.note": return .orange
        case "archivebox": return .brown
        case "gearshape": return .gray
        case "cylinder.split.1x2": return .teal
        default: return .secondary
        }
    }

    var detail: String {
        if isBrokenLink { return "broken link → \(linkTarget ?? "?")" }
        if isSymlink { return "→ \(linkTarget ?? "?")" }
        if isDirectory { return "folder" }
        return "\(Fmt.bytes(size)) · \(Fmt.date(modified))"
    }
}

final class BrowserModel: ObservableObject {
    let root: String
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var error: String?
    @Published private(set) var loading = false

    private var handle: Int64 = -1
    private let queue = DispatchQueue(label: "worse_finder.browse", qos: .userInitiated)

    init(root: String) {
        self.root = root
        if let group = wq_app_group() {
            handle = wq_grant(root, group, false)
        }
        load()
    }

    deinit {
        if handle >= 0 { wq_release(handle) }
    }

    func load() {
        loading = true
        let path = root
        let hasAccess = handle >= 0
        let reason = hasAccess ? "" : (wq_last_error() ?? "no sandbox extension")

        queue.async {
            guard hasAccess else {
                let missing = reason.contains("does not exist")
                DispatchQueue.main.async {
                    self.error = missing
                        ? "This folder no longer exists on the device. It was probably left behind by an earlier install."
                        : "The sandbox refused to extend access to this path.\n\(reason)"
                    self.loading = false
                }
                return
            }

            var result: [FileItem] = []
            var failure: String?

            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: path)
                for name in names {
                    let full = (path as NSString).appendingPathComponent(name)
                    var linkInfo = stat()
                    guard lstat(full, &linkInfo) == 0 else { continue }

                    let isLink = (linkInfo.st_mode & S_IFMT) == S_IFLNK
                    var resolved = stat()
                    let resolves = stat(full, &resolved) == 0
                    let isDirectory = resolves && (resolved.st_mode & S_IFMT) == S_IFDIR
                    let size = resolves ? Int64(resolved.st_size) : Int64(linkInfo.st_size)
                    let target = isLink
                        ? (try? FileManager.default.destinationOfSymbolicLink(atPath: full))
                        : nil

                    result.append(FileItem(
                        name: name,
                        path: full,
                        isDirectory: isDirectory,
                        isSymlink: isLink,
                        isBrokenLink: isLink && !resolves,
                        size: size,
                        modified: Date(timeIntervalSince1970: TimeInterval(linkInfo.st_mtimespec.tv_sec)),
                        linkTarget: target))
                }
            } catch {
                failure = BrowserModel.describe(error)
            }

            result.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

            DispatchQueue.main.async {
                self.items = result
                self.error = failure
                self.loading = false
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let code = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? nsError.code
        switch code {
        case Int(ENOENT):
            return "This folder no longer exists on the device. It was probably left behind by an earlier install."
        case Int(EACCES), Int(EPERM):
            return "The sandbox denied access to this folder. It may belong to a system service that is not reachable from an app container."
        default:
            return nsError.localizedDescription
        }
    }
}

struct FileBrowserView: View {
    @StateObject private var model: BrowserModel
    private let title: String
    private let containerRoot: String
    @State private var preview: FileItem?

    init(root: String, title: String, containerRoot: String? = nil) {
        _model = StateObject(wrappedValue: BrowserModel(root: root))
        self.title = title
        self.containerRoot = containerRoot ?? root
    }

    private var shortPath: String {
        let root = model.root
        guard root != containerRoot else { return "/" }
        return "~" + root.replacingOccurrences(of: containerRoot, with: "")
    }

    var body: some View {
        List {
            ForEach(model.items) { item in
                if item.isDirectory && !item.isBrokenLink {
                    NavigationLink {
                        FileBrowserView(root: item.path, title: item.name, containerRoot: containerRoot)
                    } label: {
                        row(item)
                    }
                } else {
                    Button {
                        if !item.isSymlink { preview = item }
                    } label: {
                        row(item)
                    }
                    .buttonStyle(.plain)
                    .disabled(item.isSymlink)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.load() } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(shortPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Text("\(model.items.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .overlay {
            if model.loading && model.items.isEmpty {
                EmptyStateView(symbol: "folder", tint: .blue, title: "Opening",
                               message: shortPath, action: nil, spinning: true)
            } else if let error = model.error {
                EmptyStateView(symbol: "lock.slash", tint: .orange,
                               title: "Can't open this folder", message: error,
                               action: ("Try again", { model.load() }))
            } else if model.items.isEmpty {
                EmptyStateView(symbol: "tray", tint: .gray, title: "Empty folder",
                               message: "Nothing has been written here yet.",
                               action: ("Refresh", { model.load() }))
            }
        }
        .sheet(item: $preview) { item in
            FilePreview(item: item)
        }
    }

    private func row(_ item: FileItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .foregroundStyle(item.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(item.isBrokenLink ? .secondary : .primary)
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

struct FilePreview: View {
    let item: FileItem
    @Environment(\.dismiss) private var dismiss
    @State private var content: PreviewContent = .loading

    enum PreviewContent {
        case loading
        case image(UIImage)
        case text(String)
        case hex(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch content {
                case .loading:
                    ProgressView()
                case .image(let image):
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 1200)
                    }
                case .text(let text):
                    ScrollView {
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                case .hex(let dump):
                    ScrollView {
                        Text(dump)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                case .failed(let message):
                    ContentUnavailableView("Cannot preview", systemImage: "eye.slash", description: Text(message))
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .task { load() }
    }

    private func load() {
        let path = item.path
        let ext = (item.name as NSString).pathExtension.lowercased()

        DispatchQueue.global(qos: .userInitiated).async {
            if ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp"].contains(ext),
               let image = UIImage(contentsOfFile: path) {
                DispatchQueue.main.async { content = .image(image) }
                return
            }

            if item.size < 512 * 1024,
               let text = try? String(contentsOfFile: path, encoding: .utf8),
               !text.isEmpty {
                DispatchQueue.main.async { content = .text(text) }
                return
            }

            guard let handle = FileHandle(forReadingAtPath: path) else {
                DispatchQueue.main.async { content = .failed("The sandbox denied this file.") }
                return
            }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 1024)) ?? Data()
            guard !data.isEmpty else {
                DispatchQueue.main.async { content = .failed("File is empty.") }
                return
            }

            let bytes = [UInt8](data)
            var dump = ""
            var offset = 0
            while offset < bytes.count {
                let slice = bytes[offset..<min(offset + 16, bytes.count)]
                let hex = slice.map { String(format: "%02x ", $0) }.joined()
                    .padding(toLength: 48, withPad: " ", startingAt: 0)
                let ascii = slice.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." }
                dump += String(format: "%08x  ", offset) + hex + " " + String(ascii) + "\n"
                offset += 16
            }
            DispatchQueue.main.async { content = .hex(dump) }
        }
    }
}

//
//  AppsView.swift
//  worse_finder
//

import SwiftUI
import UIKit

struct AppsView: View {
    @ObservedObject var store: Store
    @StateObject private var icons = IconCache()
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var pushed = false
    private let forceEmpty = CommandLine.arguments.contains("--empty")

    private static var launchApp: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--app"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @AppStorage("showSystemApps") private var showSystem = false
    @AppStorage("showUnknownContainers") private var showUnknown = false

    private var visible: [AppEntry] {
        store.apps.filter { app in
            (showSystem || !app.isSystem) && (showUnknown || app.bundleID != nil)
        }
    }

    private var filtered: [AppEntry] {
        if forceEmpty { return [] }
        guard !query.isEmpty else { return visible }
        return visible.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    private var hidden: Int { store.apps.count - visible.count }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(filtered) { app in
                    NavigationLink(value: app) {
                        AppRow(app: app, icons: icons)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Apps")
            .navigationDestination(for: AppEntry.self) { app in
                AppDetailView(app: app, store: store, icons: icons)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show system apps", isOn: $showSystem)
                        Toggle("Show unidentified containers", isOn: $showUnknown)
                    } label: {
                        Image(systemName: showSystem ? "line.3.horizontal.decrease.circle.fill"
                                                     : "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.scan()
                    } label: {
                        if store.scanning {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(store.scanning)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 6) {
                    if store.scanning { ProgressView().controlSize(.mini) }
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if hidden > 0 && !store.scanning {
                        Text("\(hidden) hidden")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .task {
                if store.apps.isEmpty { store.scan() }
                pushLaunchApp(store.apps)
            }
            .onChange(of: store.apps) { _, apps in
                pushLaunchApp(apps)
            }
            .overlay {
                if filtered.isEmpty { emptyState }
            }
        }
    }

    private func pushLaunchApp(_ apps: [AppEntry]) {
        guard !pushed, let bundleID = Self.launchApp,
              let app = apps.first(where: { $0.bundleID == bundleID }) else { return }
        pushed = true
        path.append(app)
    }

    private var statusLine: String {
        if store.scanning { return "reading containers…" }
        if store.apps.isEmpty { return "no scan yet" }
        return "\(filtered.count) of \(visible.count) apps"
    }

    // MARK: - empty state

    @ViewBuilder
    private var emptyState: some View {
        if store.scanning {
            EmptyStateView(symbol: "hourglass",
                           tint: .blue,
                           title: "Reading containers",
                           message: "Scanning inodes and parsing the LaunchServices store.",
                           action: nil,
                           spinning: true)
        } else if store.apps.isEmpty {
            EmptyStateView(symbol: "square.grid.2x2",
                           tint: .blue,
                           title: "No apps yet",
                           message: "Nothing has been read from this device. Run a scan to list every app container.",
                           action: ("Scan containers", { store.scan() }))
        } else if !query.isEmpty {
            EmptyStateView(symbol: "magnifyingglass",
                           tint: .gray,
                           title: "No matches",
                           message: "Nothing here is called “\(query)”.",
                           action: ("Clear search", { query = "" }))
        } else {
            EmptyStateView(symbol: "eye.slash",
                           tint: .purple,
                           title: "Only system apps here",
                           message: "\(hidden) system apps are hidden. They are still browsable and exportable.",
                           action: ("Show system apps", { showSystem = true }))
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    let action: (String, () -> Void)?
    var spinning: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.45)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                    .shadow(color: tint.opacity(0.35), radius: 18, y: 8)

                if spinning {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.white)
                }
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

struct AppIcon: View {
    let app: AppEntry
    @ObservedObject var icons: IconCache

    var body: some View {
        Group {
            if let bundleID = app.bundleID, let image = icons.images[bundleID] {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(app.tint.gradient)
                    .overlay {
                        Text(app.initials)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
            }
        }
        .onAppear {
            if let bundleID = app.bundleID { icons.load(bundleID) }
        }
    }
}

struct AppRow: View {
    let app: AppEntry
    @ObservedObject var icons: IconCache

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(app: app, icons: icons)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(app.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if app.isSystem {
                Text("system")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

struct AppDetailView: View {
    let app: AppEntry
    @ObservedObject var store: Store
    @ObservedObject var icons: IconCache

    @State private var size: Int64?
    @State private var fileCount: Int?
    @State private var measuring = false

    @State private var exporting = false
    @State private var progressFiles = 0
    @State private var progressBytes: Int64 = 0
    @State private var result: ExportResult?
    @State private var errorText: String?
    @State private var exporter: Exporter?
    @State private var showExportSheet = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppIcon(app: app, icons: icons)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.displayName).font(.headline)
                        Text(app.bundleID ?? "unknown identifier")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Contents") {
                NavigationLink {
                    FileBrowserView(root: app.container, title: app.displayName)
                } label: {
                    Label("Browse files", systemImage: "folder")
                }

                Button {
                    startExport()
                } label: {
                    Label("Export as ZIP", systemImage: "doc.zipper")
                }
            }

            if !app.groups.isEmpty {
                Section {
                    ForEach(app.groups) { group in
                        NavigationLink {
                            FileBrowserView(root: group.path, title: group.identifier)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.identifier)
                                    .font(.footnote)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(String(group.path.suffix(8)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("App Groups")
                } footer: {
                    Text("Shared containers this app writes to. Browsable and exportable like any other.")
                }
            }

            if !app.alternates.isEmpty {
                Section {
                    ForEach(app.alternates, id: \.self) { path in
                        NavigationLink {
                            FileBrowserView(root: path, title: "Container " + String(path.suffix(8)))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Container " + String(path.suffix(8)))
                                Text(path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                    }
                } header: {
                    Text("Other containers")
                } footer: {
                    Text("Earlier installs of this app left these behind. They are browsable and exportable too.")
                }
            }

            Section("Container") {
                LabeledContent("Size") {
                    if let size {
                        Text("\(Fmt.bytes(size))\(fileCount.map { " · \($0) files" } ?? "")")
                    } else if measuring {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("not measured").foregroundStyle(.secondary)
                    }
                }
                Button("Measure") { measure() }
                    .disabled(measuring)

                Text(app.container)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(app.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(app: app,
                        exporting: $exporting,
                        files: progressFiles,
                        bytes: progressBytes,
                        result: result,
                        errorText: errorText,
                        cancel: { exporter?.cancel() })
        }
    }

    private func measure() {
        measuring = true
        store.measure(app) { bytes, files in
            size = bytes
            fileCount = files
            measuring = false
        }
    }

    private func startExport() {
        progressFiles = 0
        progressBytes = 0
        result = nil
        errorText = nil
        exporting = true
        showExportSheet = true

        let runner = Exporter()
        exporter = runner
        let name = app.displayName
        let container = app.container

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let outcome = try runner.run(container: container, name: name) { files, bytes in
                    DispatchQueue.main.async {
                        progressFiles = files
                        progressBytes = bytes
                    }
                }
                DispatchQueue.main.async {
                    result = outcome
                    size = outcome.bytes
                    fileCount = outcome.files
                    exporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorText = error.localizedDescription
                    exporting = false
                }
            }
        }
    }
}

struct ExportSheet: View {
    let app: AppEntry
    @Binding var exporting: Bool
    let files: Int
    let bytes: Int64
    let result: ExportResult?
    let errorText: String?
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var archiveSize: Int64?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                if let result {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.green)
                    Text("Archive ready").font(.headline)
                    VStack(spacing: 4) {
                        Text("\(result.files) files · \(Fmt.bytes(result.bytes))")
                        Text("\(Fmt.bytes(archiveSize ?? 0)) archive · \(String(format: "%.1f", result.seconds))s")
                        if result.skipped > 0 {
                            Text("\(result.skipped) items skipped (symlinks)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    ShareLink(item: result.url) {
                        Label("Share archive", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    Text(result.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .task {
                            let attributes = try? FileManager.default.attributesOfItem(atPath: result.url.path)
                            archiveSize = attributes?[.size] as? Int64
                        }

                } else if let errorText {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Export failed").font(.headline)
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                } else {
                    ProgressView()
                        .controlSize(.large)
                    Text("Archiving \(app.displayName)").font(.headline)
                    Text("\(files) files · \(Fmt.bytes(bytes))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Cancel", role: .destructive) { cancel() }
                        .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding(24)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(exporting)
                }
            }
            .interactiveDismissDisabled(exporting)
        }
    }
}

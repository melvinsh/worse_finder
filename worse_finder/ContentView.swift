//
//  ContentView.swift
//  worse_finder
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = Store()
    @StateObject private var server = WebServer()
    @State private var tab = CommandLine.arguments.contains("--server-tab") ? 1
        : CommandLine.arguments.contains("--settings-tab") ? 2 : 0

    private var debugBrowsePath: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--browse-path"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    var body: some View {
        if let path = debugBrowsePath {
            NavigationStack {
                FileBrowserView(root: path,
                                title: (path as NSString).lastPathComponent,
                                containerRoot: ContentView.containerRoot(of: path))
            }
        } else {
            tabs
        }
    }

    /// /private/var/mobile/Containers/Data/Application/<uuid> for a path inside it.
    static func containerRoot(of path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "Application"), parts.count > index + 1 else { return path }
        return "/" + parts[0...index + 1].joined(separator: "/")
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            AppsView(store: store)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2.fill") }
                .tag(0)

            ServerView(store: store, server: server)
                .tabItem { Label("Server", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)

            SettingsView(store: store, server: server)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(2)
        }
        .task {
            server.appsProvider = { store.apps }
            if store.apps.isEmpty { store.scan() }
            if CommandLine.arguments.contains("--serve") {
                server.start()
                for (name, address) in Interfaces.detailed() {
                    print("[http] \(name) https://\(address):\(server.port)/")
                }
            }
        }
    }
}

#Preview {
    ContentView()
}

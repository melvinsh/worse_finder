//
//  ServerView.swift
//  worse_finder
//

import SwiftUI
import UIKit

struct ServerView: View {
    @ObservedObject var store: Store
    @ObservedObject var server: WebServer
    @State private var copied: String?

    private var addresses: [String] { Interfaces.addresses() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Circle()
                            .fill(server.running ? Color.green : Color.secondary)
                            .frame(width: 9, height: 9)
                        Text(server.running ? "listening on :\(String(server.port))" : "stopped")
                            .font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        Text("\(server.hits) requests")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        if server.running { server.stop() } else { server.start() }
                    } label: {
                        Label(server.running ? "Stop server" : "Start server",
                              systemImage: server.running ? "stop.circle.fill" : "play.circle.fill")
                    }
                    .tint(server.running ? .red : .accentColor)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Plain HTTP on the local network. Anyone with the passphrase can read every app container this phone can reach.")
                }

                Section("Open on another device") {
                    if addresses.isEmpty {
                        Text("No Wi-Fi address — connect to a network first.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(addresses, id: \.self) { address in
                            let url = "http://\(address):\(server.port)/?k=\(server.passphrase)"
                            Button {
                                UIPasteboard.general.string = url
                                flash("url")
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    Text(copied == "url" ? "copied" : "tap to copy")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Passphrase") {
                    Button {
                        UIPasteboard.general.string = server.passphrase
                        flash("pass")
                    } label: {
                        HStack {
                            Text(server.passphrase)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: copied == "pass" ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Generate a new passphrase", role: .destructive) {
                        server.rotatePassphrase()
                    }
                }

                Section("Requests") {
                    if server.log.isEmpty {
                        Text("No requests yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(server.log.suffix(40).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Server")
            .task {
                server.appsProvider = { store.apps }
                if store.apps.isEmpty { store.scan() }
            }
            .onDisappear {
                if !server.running { server.stop() }
            }
        }
    }

    private func flash(_ key: String) {
        copied = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copied == key { copied = nil }
        }
    }
}

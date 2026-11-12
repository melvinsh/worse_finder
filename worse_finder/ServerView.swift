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
                    Text("HTTPS on the local network, with a self-signed certificate. The browser warning is expected; compare it with the fingerprint below. Anyone with the password can read every app container this phone can reach.")
                }

                Section("Open on another device") {
                    if addresses.isEmpty {
                        Text("No Wi-Fi address — connect to a network first.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(addresses, id: \.self) { address in
                            let url = "https://\(address):\(server.port)/#k=\(server.password.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? server.password)"
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

                Section("Password") {
                    Button {
                        UIPasteboard.general.string = server.password
                        flash("pass")
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(server.password)
                                .font(.system(size: 15, design: .monospaced))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: copied == "pass" ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Generate a new password", role: .destructive) {
                        server.rotatePassword()
                    }
                }

                Section {
                    Button {
                        UIPasteboard.general.string = server.fingerprint
                        flash("cert")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.fingerprint.isEmpty ? "Unavailable" : server.fingerprint)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(copied == "cert" ? "copied" : "SHA-256 fingerprint")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(server.fingerprint.isEmpty)
                } header: {
                    Text("Certificate")
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
                server.refreshIdentity()
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

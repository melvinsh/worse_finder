//
//  SettingsView.swift
//  worse_finder
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var server: WebServer

    @AppStorage("showSystemApps") private var showSystem = false
    @AppStorage("showUnknownContainers") private var showUnknown = false

    private var systemCount: Int { store.apps.filter(\.isSystem).count }
    private var unknownCount: Int { store.apps.filter { $0.bundleID == nil }.count }
    private var visibleCount: Int {
        store.apps.filter { ($0.isSystem == false || showSystem) && ($0.bundleID != nil || showUnknown) }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image("Brand")
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("worse_finder")
                                .font(.title3.weight(.semibold))
                            Text("Every app container on this iPhone, browsable and exportable.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Toggle("Show system apps", isOn: $showSystem)
                    Toggle("Show unidentified containers", isOn: $showUnknown)
                } header: {
                    Text("Apps")
                } footer: {
                    Text("\(systemCount) system apps and \(unknownCount) unidentified containers on this device. "
                         + "Hiding them keeps the list to apps you installed. The web server always lists every container.")
                }

                Section {
                    Button {
                        store.scan()
                    } label: {
                        HStack {
                            Text("Rescan containers")
                            Spacer()
                            if store.scanning { ProgressView().controlSize(.mini) }
                        }
                    }
                    .disabled(store.scanning)

                    Button("Clear cache", role: .destructive) {
                        store.clearCache()
                    }
                    .disabled(store.apps.isEmpty)
                } header: {
                    Text("Data")
                } footer: {
                    Text(store.status.isEmpty ? "No scan yet." : store.status)
                }

                Section("Overview") {
                    LabeledContent("Containers found", value: "\(store.apps.count)")
                    LabeledContent("Visible in Apps", value: "\(visibleCount)")
                    LabeledContent("Web server", value: server.running ? "on :\(String(server.port))" : "off")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Password")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(server.password)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Section {
                    LabeledContent("Technique", value: "worse_query")
                    LabeledContent("Supported", value: "iOS 26.0 – 27.2")
                    LabeledContent("Version", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                                   + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") + ")")
                    LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "?")
                } header: {
                    Text("About")
                } footer: {
                    Text("A proof of concept: the sandbox escape gives this app read-write access to every app container on the device.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

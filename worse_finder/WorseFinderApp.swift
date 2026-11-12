//
//  WorseFinderApp.swift
//  worse_finder
//

import SwiftUI

@main
struct WorseFinderApp: App {
    init() {
        if CommandLine.arguments.contains("--show-system") {
            UserDefaults.standard.set(true, forKey: "showSystemApps")
        }
        if CommandLine.arguments.contains("--fixture") {
            Fixture.create()
        }
        if CommandLine.arguments.contains("--export-check") {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
                Diagnostics.runExportCheck()
            }
        }
        if CommandLine.arguments.contains("--walkie") {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
                Diagnostics.runWalkie()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Deterministic files for exercising the browser: symlinks, a broken link,
/// an empty folder and three levels of nesting.
enum Fixture {
    static func check(_ root: String) {
        let paths = [root,
                     root + "/empty-folder",
                     root + "/nested/a/b",
                     "/private/var/mobile/Containers/Data/Application/6C290247-D632-46B3-AF29-8AD14A1A2868"]
        var models: [BrowserModel] = []
        for path in paths {
            let model = BrowserModel(root: path)
            models.append(model)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for (model, path) in zip(models, paths) {
                let names = model.items.prefix(4).map(\.name).joined(separator: ", ")
                print("[check] \(path.replacingOccurrences(of: root, with: "~")) items=\(model.items.count) error=\(model.error ?? "none") [\(names)]")
            }
        }
    }

    static func create() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fm = FileManager.default
        try? fm.createDirectory(at: documents.appendingPathComponent("empty-folder"), withIntermediateDirectories: true)
        let nested = documents.appendingPathComponent("nested/a/b")
        try? fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try? "level three\n".write(to: nested.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try? "level two\n".write(to: documents.appendingPathComponent("nested/a/note.txt"), atomically: true, encoding: .utf8)

        let linkDirectory = documents.appendingPathComponent("symlink-to-library")
        try? fm.removeItem(at: linkDirectory)
        try? fm.createSymbolicLink(atPath: linkDirectory.path, withDestinationPath: "../Library")

        let broken = documents.appendingPathComponent("broken-link")
        try? fm.removeItem(at: broken)
        try? fm.createSymbolicLink(atPath: broken.path, withDestinationPath: "does-not-exist.txt")
        print("[fixture] wrote browser fixtures to \(documents.path)")

        if CommandLine.arguments.contains("--fixture-check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Fixture.check(documents.path) }
        }
    }
}

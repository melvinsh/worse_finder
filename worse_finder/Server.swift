//
//  Server.swift
//  worse_finder
//
//  Small HTTP server exposing the same surface as the Apps tab: list apps,
//  browse a container, download a file, export a container as ZIP.
//  Gated by a three word passphrase.
//

import Foundation
import Network
import UIKit

// MARK: - passphrase

enum Passphrase {
    private static let words = [
        "amber", "anchor", "apple", "arrow", "aspen", "atlas", "autumn", "badger",
        "bamboo", "barrel", "basalt", "beacon", "beetle", "birch", "bison", "blossom",
        "bramble", "breeze", "bronze", "bubble", "cactus", "candle", "canyon", "cedar",
        "chalk", "cinder", "cobalt", "comet", "copper", "coral", "cosmos", "cotton",
        "crater", "crimson", "crystal", "cypress", "dahlia", "daisy", "delta", "denim",
        "desert", "dolphin", "dragon", "drift", "dune", "eagle", "ember", "emerald",
        "falcon", "feather", "fern", "fjord", "flint", "fossil", "fox", "frost",
        "galaxy", "garnet", "geyser", "glacier", "granite", "grape", "grove", "harbor",
        "hazel", "heron", "hickory", "hollow", "honey", "indigo", "ivory", "jade",
        "jasper", "juniper", "kelp", "kite", "lagoon", "lantern", "larch", "lava",
        "lemon", "lilac", "linen", "lobster", "lotus", "lunar", "lynx", "magnet",
        "mango", "maple", "marble", "meadow", "mesa", "meteor", "mint", "mist",
        "moss", "nebula", "nickel", "north", "nutmeg", "oak", "obsidian", "ochre",
        "olive", "onyx", "opal", "orbit", "otter", "pebble", "pepper", "pine",
        "pixel", "plum", "prairie", "prism", "quartz", "quill", "raven", "reef",
        "ridge", "river", "robin", "ruby", "rust", "saffron", "sage", "sail",
        "sand", "sapphire", "shadow", "shell", "silver", "slate", "snow", "solar",
        "sparrow", "spruce", "steel", "stone", "storm", "summit", "sunset", "tundra",
        "turquoise", "valley", "velvet", "violet", "walnut", "willow", "wolf", "zephyr",
    ]

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        var picked: [String] = []
        while picked.count < 3 {
            let word = words.randomElement(using: &generator) ?? "amber"
            if !picked.contains(word) { picked.append(word) }
        }
        return picked.joined(separator: "-")
    }

    static func current() -> String {
        let key = "worse_finder.passphrase"
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty { return stored }
        let fresh = generate()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    static func rotate() -> String {
        let fresh = generate()
        UserDefaults.standard.set(fresh, forKey: "worse_finder.passphrase")
        return fresh
    }
}

// MARK: - interfaces

enum Interfaces {
    /// (interface, address) for every non-loopback IPv4 address.
    static func detailed() -> [(String, String)] {
        var results: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return results }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: host)
                let name = String(cString: pointer.pointee.ifa_name)
                if !text.isEmpty { results.append((name, text)) }
            }
        }
        return results
    }

    /// Wi-Fi first, then everything else.
    static func addresses() -> [String] {
        let all = detailed()
        let preferred = all.filter { $0.0 == "en0" }.map { $0.1 }
        let rest = all.filter { $0.0 != "en0" }.map { $0.1 }
        return preferred + rest
    }

}

// MARK: - server

final class WebServer: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var log: [String] = []
    @Published private(set) var hits = 0

    let port: UInt16 = 8080
    private(set) var passphrase: String

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "worse_finder.http", qos: .userInitiated, attributes: .concurrent)
    private var iconCache: [String: Data] = [:]
    private let cacheLock = NSLock()

    var appsProvider: (() -> [AppEntry])?

    init(passphrase: String) {
        self.passphrase = passphrase
    }

    func rotatePassphrase() {
        passphrase = Passphrase.rotate()
    }

    /// Exports left behind by an earlier run would otherwise be zipped again.
    static func clearStaleExports() {
        let tmp = FileManager.default.temporaryDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in entries where name.hasPrefix("http-") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    func start() {
        WebServer.clearStaleExports()
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.note("listening on \(self.port)")
                case .failed(let error): self.note("failed: \(error.localizedDescription)"); self.stop()
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            DispatchQueue.main.async { self.running = true }
        } catch {
            note("cannot listen: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { self.running = false }
        note("stopped")
    }

    private func note(_ line: String) {
        print("[http] " + line)
        DispatchQueue.main.async {
            self.log.append(line)
            if self.log.count > 200 { self.log.removeFirst(self.log.count - 200) }
        }
    }

    // MARK: connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                self.dispatch(head, connection: connection)
                return
            }
            if isComplete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
                return
            }
            self.read(connection, buffer: buffer)
        }
    }

    private func dispatch(_ head: String, connection: NWConnection) {
        let firstLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(connection, status: "400 Bad Request", body: Data("bad request".utf8))
            return
        }

        let target = String(parts[1])
        let (path, query) = split(target)
        let cookies = cookieJar(head)
        let token = query["k"] ?? cookies["wq"]

        DispatchQueue.main.async { self.hits += 1 }

        guard let token, token == passphrase else {
            note("401 \(path)")
            // One attempt per second: a 4M-combination passphrase is not
            // brute forceable at that rate.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.send(connection, status: "401 Unauthorized", type: "text/html; charset=utf-8",
                          body: Data(self.loginPage().utf8))
            }
            return
        }

        let segments = path.split(separator: "/").map(String.init)
        note("200 \(path)")

        if segments.isEmpty {
            sendApps(connection, token: token)
            return
        }

        switch segments[0] {
        case "i":
            guard segments.count > 1 else { send(connection, status: "404 Not Found", body: Data()); return }
            sendIcon(connection, bundleID: segments[1])
        case "a", "f", "z":
            guard segments.count > 1 else { send(connection, status: "404 Not Found", body: Data()); return }
            let container = appContainer(for: segments[1])
            guard let container, let group = wq_app_group() else {
                send(connection, status: "404 Not Found", type: "text/html; charset=utf-8",
                     body: Data(page("Not found", "<p>No such container.</p>").utf8))
                return
            }
            let relative = sanitize(query["p"] ?? "")
            switch segments[0] {
            case "a": sendListing(connection, container: container, relative: relative, token: token, group: group)
            case "f": sendFile(connection, container: container, relative: relative, group: group)
            default: sendZip(connection, container: container, token: token)
            }
        default:
            send(connection, status: "404 Not Found", body: Data("not found".utf8))
        }
    }

    // MARK: routes

    private func sendApps(_ connection: NWConnection, token: String) {
        let apps = appsProvider?() ?? []
        var rows = ""
        for app in apps {
            let icon = app.bundleID.map { "<img class=ic src=\"/i/\($0)?k=\(token)\" loading=lazy>" }
                ?? "<div class=ic></div>"
            let subtitle = app.subtitle.addingHTMLEntities()
            rows += """
            <a class=row href="/a/\(app.container.lastPathComponent)?k=\(token)">
              \(icon)
              <div class=t><div class=n>\(app.displayName.addingHTMLEntities())</div>
              <div class=s>\(subtitle)</div></div>
              <div class=c>›</div>
            </a>
            """
            if !app.groups.isEmpty {
                let links = app.groups.map { group in
                    "<a href=\"/a/\(group.path.lastPathComponent)?k=\(token)\">\(group.identifier.addingHTMLEntities())</a>"
                }.joined(separator: " ")
                rows += "<div class=alt>group\(app.groups.count == 1 ? "" : "s"): \(links)</div>"
            }
            if !app.alternates.isEmpty {
                let links = app.alternates.map { path in
                    "<a href=\"/a/\(path.lastPathComponent)?k=\(token)\">\(String(path.suffix(8)))</a>"
                }.joined(separator: " ")
                rows += "<div class=alt>+\(app.alternates.count) more container\(app.alternates.count == 1 ? "" : "s"): \(links)</div>"
            }
        }
        let body = """
        <h1>\(apps.count) apps</h1>
        <div class=list>\(rows)</div>
        """
        send(connection, status: "200 OK", type: "text/html; charset=utf-8",
             body: Data(page("Apps", body, token: token).utf8),
             extra: ["Set-Cookie": "wq=\(token); Path=/; Max-Age=86400; SameSite=Lax"])
    }

    private func sendListing(_ connection: NWConnection, container: String, relative: String,
                             token: String, group: String) {
        let handle = wq_grant(container, group, false)
        guard handle >= 0 else {
            send(connection, status: "500 Internal Server Error", type: "text/html; charset=utf-8",
                 body: Data(page("Denied", "<p>\(wq_last_error() ?? "no access").</p>", token: token).utf8))
            return
        }
        defer { wq_release(handle) }

        let directory = relative.isEmpty ? container : container + "/" + relative
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            send(connection, status: "404 Not Found", type: "text/html; charset=utf-8",
                 body: Data(page("Not found", "<p>No such folder.</p>", token: token).utf8))
            return
        }

        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        var items: [(String, Bool, Int64, Date?)] = []
        for name in names {
            let full = directory + "/" + name
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &folder) else { continue }
            let values = try? URL(fileURLWithPath: full)
                .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            items.append((name, folder.boolValue, Int64(values?.fileSize ?? 0), values?.contentModificationDate))
        }
        items.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 }
            return lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
        }

        let identifier = container.lastPathComponent
        var crumbs = "<a href=\"/a/\(identifier)?k=\(token)\">/</a>"
        if !relative.isEmpty {
            var accumulated = ""
            for part in relative.split(separator: "/") {
                accumulated += (accumulated.isEmpty ? "" : "/") + part
                crumbs += " <a href=\"/a/\(identifier)?k=\(token)&p=\(accumulated.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&raw=1\">\(part)</a> /"
            }
        }

        var rows = ""
        if !relative.isEmpty {
            let parent = relative.split(separator: "/").dropLast().joined(separator: "/")
            rows += "<a class=row href=\"/a/\(identifier)?k=\(token)&p=\(parent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")\"><div class=ic>↰</div><div class=t><div class=n>..</div></div></a>"
        }
        for (name, isFolder, size, modified) in items {
            let escaped = name.addingHTMLEntities()
            if isFolder {
                let path = relative.isEmpty ? name : relative + "/" + name
                let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                rows += "<a class=row href=\"/a/\(identifier)?k=\(token)&p=\(encodedPath)\"><div class=ic>▸</div><div class=t><div class=n>\(escaped)</div><div class=s>folder</div></div></a>"
            } else {
                let path = relative.isEmpty ? name : relative + "/" + name
                let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                rows += "<a class=row href=\"/f/\(identifier)?k=\(token)&p=\(encodedPath)\"><div class=ic>≡</div><div class=t><div class=n>\(escaped)</div><div class=s>\(Fmt.bytes(size)) · \(Fmt.date(modified))</div></div><div class=c>↓</div></a>"
            }
        }

        let body = """
        <div class=crumbs>\(crumbs)</div>
        <div class=actions><a class=btn href="/z/\(identifier)?k=\(token)">Download ZIP</a></div>
        <div class=list>\(rows)</div>
        """
        send(connection, status: "200 OK", type: "text/html; charset=utf-8",
             body: Data(page(relative.isEmpty ? identifier : (relative as NSString).lastPathComponent, body, token: token).utf8))
    }

    private func sendFile(_ connection: NWConnection, container: String, relative: String, group: String) {
        guard !relative.isEmpty else {
            send(connection, status: "400 Bad Request", body: Data())
            return
        }
        let handle = wq_grant(container, group, false)
        guard handle >= 0 else {
            send(connection, status: "403 Forbidden", body: Data())
            return
        }
        defer { wq_release(handle) }

        let path = container + "/" + relative
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64,
              let stream = InputStream(url: URL(fileURLWithPath: path)) else {
            send(connection, status: "404 Not Found", body: Data())
            return
        }

        let name = (relative as NSString).lastPathComponent
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: application/octet-stream\r
        Content-Length: \(size)\r
        Content-Disposition: attachment; filename="\(name)"\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        stream.open()
        pump(connection, stream: stream, handle: handle)
    }

    private func pump(_ connection: NWConnection, stream: InputStream, handle: Int64,
                      cleanup: URL? = nil) {
        let chunk = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        let read = stream.read(&buffer, maxLength: chunk)
        if read > 0 {
            connection.send(content: Data(buffer[0..<read]), completion: .contentProcessed { [weak self] error in
                if error != nil {
                    stream.close()
                    wq_release(handle)
                    connection.cancel()
                    if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
                    return
                }
                self?.pump(connection, stream: stream, handle: handle, cleanup: cleanup)
            })
            return
        }
        stream.close()
        wq_release(handle)
        connection.cancel()
        if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
    }

    private func sendZip(_ connection: NWConnection, container: String, token: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-\(UUID().uuidString)", isDirectory: true)
        let name = appContainerName(container)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try Exporter().run(container: container, name: name,
                                                outputDirectory: directory) { _, _ in }
                let archive = (try? FileManager.default.attributesOfItem(atPath: result.url.path))?[.size] as? Int64 ?? 0
                print("[export] \(container) files=\(result.files) bytes=\(result.bytes) skipped=\(result.skipped) archive=\(archive) seconds=\(String(format: "%.1f", result.seconds))")
                self.serveArchive(connection, url: result.url)
            } catch {
                self.send(connection, status: "500 Internal Server Error", type: "text/html; charset=utf-8",
                          body: Data(self.page("Export failed", "<p>\(error.localizedDescription)</p>", token: token).utf8))
            }
        }
    }

    private func serveArchive(_ connection: NWConnection, url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64,
              let stream = InputStream(url: url) else {
            send(connection, status: "500 Internal Server Error", body: Data())
            return
        }
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: application/zip\r
        Content-Length: \(size)\r
        Content-Disposition: attachment; filename="\(url.lastPathComponent)"\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        stream.open()
        // The archive is a temporary copy: drop it once it has been served.
        pump(connection, stream: stream, handle: 0, cleanup: url.deletingLastPathComponent())
    }

    private func sendIcon(_ connection: NWConnection, bundleID: String) {
        cacheLock.lock()
        let cached = iconCache[bundleID]
        cacheLock.unlock()

        if let cached {
            send(connection, status: "200 OK", type: "image/png", body: cached, extra: ["Cache-Control": "max-age=86400"])
            return
        }
        guard let data = wq_ls_icon(bundleID) else {
            send(connection, status: "404 Not Found", body: Data())
            return
        }
        cacheLock.lock()
        iconCache[bundleID] = data
        cacheLock.unlock()
        send(connection, status: "200 OK", type: "image/png", body: data, extra: ["Cache-Control": "max-age=86400"])
    }

    // MARK: helpers

    /// Every container the server will serve: app data, leftover containers and
    /// app groups, keyed by the UUID in the URL.
    private func containerIndex() -> [String: (path: String, name: String, bundleID: String?)] {
        var index: [String: (path: String, name: String, bundleID: String?)] = [:]
        for app in appsProvider?() ?? [] {
            index[app.container.lastPathComponent] = (app.container, app.displayName, app.bundleID)
            for alternate in app.alternates {
                index[alternate.lastPathComponent] = (alternate, app.displayName + " (earlier install)", app.bundleID)
            }
            for group in app.groups {
                index[group.path.lastPathComponent] = (group.path, app.displayName + " · " + group.identifier, app.bundleID)
            }
        }
        return index
    }

    /// The row can go stale between scan and request: a reinstall replaces the
    /// container. Fall back to whatever LaunchServices reports now.
    private func appContainer(for identifier: String) -> String? {
        guard let entry = containerIndex()[identifier] else { return nil }
        var info = stat()
        if lstat(entry.path, &info) == 0 { return entry.path }
        if let bundleID = entry.bundleID, let fresh = wq_ls_container(bundleID) {
            var probe = stat()
            if lstat(fresh, &probe) == 0 {
                print("[http] container moved: \(entry.path) -> \(fresh)")
                return fresh
            }
        }
        return entry.path
    }

    private func appContainerName(_ container: String) -> String {
        let identifier = container.lastPathComponent
        if let name = containerIndex()[identifier]?.name { return name }
        return identifier
    }

    private func sanitize(_ value: String) -> String {
        var clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        while clean.contains("//") { clean = clean.replacingOccurrences(of: "//", with: "/") }
        if clean.contains("..") { return "" }
        return clean
    }

    private func split(_ target: String) -> (String, [String: String]) {
        guard let question = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<question])
        var query: [String: String] = [:]
        for pair in target[target.index(after: question)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            query[String(key).removingPercentEncoding ?? String(key)] =
                value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
        }
        return (path, query)
    }

    private func cookieJar(_ head: String) -> [String: String] {
        var cookies: [String: String] = [:]
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("cookie:") {
            let value = line.dropFirst(7)
            for pair in value.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                cookies[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return cookies
    }

    private func send(_ connection: NWConnection, status: String, type: String = "text/plain; charset=utf-8",
                      body: Data, extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (key, value) in extra { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: pages

    private func loginPage() -> String {
        page("Locked", """
        <h1>Locked</h1>
        <p>Append <code>?k=your-passphrase</code> to the URL, or open the link shown in the app.</p>
        <form method=get>
          <input name=k placeholder="passphrase" autofocus>
          <button>Unlock</button>
        </form>
        """)
    }

    private func page(_ title: String, _ content: String, token: String? = nil) -> String {
        """
        <!doctype html><html><head><meta charset=utf-8>
        <meta name=viewport content="width=device-width,initial-scale=1">
        <title>\(title)</title>
        <style>
        :root{color-scheme:dark}
        *{box-sizing:border-box}
        body{margin:0;font:15px/1.4 -apple-system,system-ui,sans-serif;background:#0d0f12;color:#e8eaed}
        header{position:sticky;top:0;background:#0d0f12ee;backdrop-filter:blur(10px);padding:14px 16px;border-bottom:1px solid #1e232b}
        header b{font-size:17px}
        main{padding:12px 12px 60px;max-width:760px;margin:0 auto}
        h1{font-size:15px;font-weight:600;color:#9aa4b2;margin:8px 4px 12px}
        .list{background:#14181e;border:1px solid #1e232b;border-radius:14px;overflow:hidden}
        .row{display:flex;align-items:center;gap:12px;padding:10px 14px;color:inherit;text-decoration:none;border-bottom:1px solid #1b2027}
        .row:last-child{border-bottom:0}
        .row:active{background:#1b2129}
        .ic{width:36px;height:36px;border-radius:9px;background:#20262f;display:flex;align-items:center;justify-content:center;flex:0 0 36px;color:#7d8797;font-size:15px}
        img.ic{object-fit:cover;background:transparent}
        .t{min-width:0;flex:1}
        .n{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .s{font-size:12px;color:#7d8797;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .c{color:#4d5663;font-size:18px}
        .alt{padding:0 14px 10px 62px;font-size:11px;color:#7d8797;margin-top:-6px}
        .alt a{color:#6aa8ff;text-decoration:none}
        .crumbs{padding:6px 4px 12px;font-size:12px;color:#7d8797;word-break:break-all}
        .crumbs a{color:#6aa8ff;text-decoration:none}
        .actions{margin:0 0 12px}
        .btn{display:inline-block;background:#2b6cf6;color:#fff;text-decoration:none;padding:10px 16px;border-radius:10px;font-weight:600;font-size:14px}
        code{background:#1b2027;padding:2px 6px;border-radius:6px}
        input{background:#14181e;border:1px solid #2a313b;color:#e8eaed;padding:10px 12px;border-radius:10px;width:100%;margin:8px 0}
        button{background:#2b6cf6;border:0;color:#fff;padding:10px 16px;border-radius:10px;font-weight:600}
        </style></head><body>
        <header><b>worse_finder</b>\(token.map { " · <a href=\"/?k=\($0)\" style=\"color:#6aa8ff;text-decoration:none\">apps</a>" } ?? "")</header>
        <main>\(content)</main></body></html>
        """
    }
}

extension String {
    var lastPathComponent: String { (self as NSString).lastPathComponent }

    func addingHTMLEntities() -> String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

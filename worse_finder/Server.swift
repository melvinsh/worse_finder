//
//  Server.swift
//  worse_finder
//
//  Small HTTPS server exposing the same surface as the Apps tab: list apps,
//  browse a container, download a file, export a container as ZIP.
//  Gated by a 160-bit password.
//

import Foundation
import Network
import Security
import UIKit

// MARK: - password

enum ServerPassword {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    private static let lock = NSLock()
    private static var memory: String?
    private static let legacyDefaultsKey = "worse_finder.passphrase"
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "worse_finder",
        kSecAttrAccount as String: "password",
    ]

    /// Grouped for display: `xxxx-xxxx-…`, eight groups.
    static func current() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let memory { return grouped(memory) }
        forgetLegacy()
        if let stored = read(), isCanonical(stored) {
            memory = stored
            return grouped(stored)
        }
        let fresh = generate()
        write(fresh)
        memory = fresh
        return grouped(fresh)
    }

    static func rotate() -> String {
        lock.lock()
        defer { lock.unlock() }
        let fresh = generate()
        write(fresh)
        memory = fresh
        forgetLegacy()
        return grouped(fresh)
    }

    static func canonical(_ value: String) -> String { normalize(value) }

    static func matches(_ provided: String) -> Bool {
        let secret = canonical(current())
        return constantTimeEqual(normalize(provided), secret)
    }

    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0...255, using: &generator)
            }
        }
        var buffer = 0
        var bits = 0
        var out = ""
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 31])
            }
        }
        return out
    }

    private static func grouped(_ canonical: String) -> String {
        var parts: [String] = []
        var rest = canonical
        while !rest.isEmpty {
            let end = rest.index(rest.startIndex, offsetBy: min(4, rest.count))
            parts.append(String(rest[..<end]))
            rest = String(rest[end...])
        }
        return parts.joined(separator: "-")
    }

    private static func normalize(_ value: String) -> String {
        String(value.lowercased().filter { $0 != "-" && !$0.isWhitespace })
    }

    private static func isCanonical(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { alphabet.contains($0) }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var diff = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0
            let y = index < right.count ? right[index] : 0
            diff |= Int(x ^ y)
        }
        return diff == 0
    }

    private static func read() -> String? {
        var copy = query
        copy[kSecReturnData as String] = true
        copy[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(copy as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func write(_ canonical: String) {
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = Data(canonical.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func forgetLegacy() {
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
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

private final class Slot {
    private let releaseBody: () -> Void
    private var done = false
    private let lock = NSLock()

    init(_ releaseBody: @escaping () -> Void) { self.releaseBody = releaseBody }

    func close() {
        lock.lock()
        let should = !done
        done = true
        lock.unlock()
        if should { releaseBody() }
    }
}

private final class AuthState {
    enum Verdict {
        case ok
        case missing
        case denied
        case locked(Int)
    }

    private let lock = NSLock()
    private var failures = 0
    private var lockedUntil = Date.distantPast
    private var pending = 0

    func reserve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pending >= 8 { return false }
        pending += 1
        return true
    }

    func release() {
        lock.lock()
        if pending > 0 { pending -= 1 }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        failures = 0
        lockedUntil = .distantPast
        lock.unlock()
    }

    /// `presented == nil` is not an attempt. A lockout rejects without checking the secret.
    func verify(presented: String?) -> Verdict {
        lock.lock()
        let now = Date()
        if now < lockedUntil {
            let retry = max(1, Int(ceil(lockedUntil.timeIntervalSince(now))))
            lock.unlock()
            return presented == nil ? .missing : .locked(retry)
        }
        lock.unlock()

        guard let presented else { return .missing }
        let ok = ServerPassword.matches(presented)

        lock.lock()
        defer { lock.unlock() }
        let after = Date()
        if !ok && after < lockedUntil {
            return .locked(max(1, Int(ceil(lockedUntil.timeIntervalSince(after)))))
        }
        if ok {
            failures = 0
            lockedUntil = .distantPast
            return .ok
        }
        failures += 1
        if failures >= 5 {
            let shift = min(failures - 5, 10)
            let delay = min(15 * 60, 1 << shift)
            lockedUntil = after.addingTimeInterval(TimeInterval(delay))
            return .locked(delay)
        }
        return .denied
    }
}

final class WebServer: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var log: [String] = []
    @Published private(set) var hits = 0
    @Published private(set) var password: String
    @Published private(set) var fingerprint = ""

    let port: UInt16 = 8443

    private var listener: NWListener?
    private var tlsIdentity: TLSIdentity?
    private let queue = DispatchQueue(label: "worse_finder.http", qos: .userInitiated, attributes: .concurrent)
    private var iconCache: [String: Data] = [:]
    private let cacheLock = NSLock()
    private let auth = AuthState()

    var appsProvider: (() -> [AppEntry])?

    init() {
        password = ServerPassword.current()
    }

    func rotatePassword() {
        password = ServerPassword.rotate()
        auth.reset()
    }

    /// Loads or re-signs the certificate for the addresses currently up.
    @discardableResult
    func refreshIdentity() -> TLSIdentity? {
        do {
            let identity = try TLSIdentity.load(addresses: Interfaces.addresses())
            tlsIdentity = identity
            if fingerprint != identity.fingerprint { fingerprint = identity.fingerprint }
            return identity
        } catch {
            note("certificate: \(error)")
            return nil
        }
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
        guard let identity = refreshIdentity() else { return }
        do {
            let listener = try NWListener(using: identity.parameters(), on: NWEndpoint.Port(rawValue: port)!)
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
        guard auth.reserve() else {
            note("dropped unauthenticated connection")
            connection.cancel()
            return
        }
        let slot = Slot { [weak self] in self?.auth.release() }
        connection.start(queue: queue)
        read(connection, buffer: Data(), slot: slot)
    }

    private func read(_ connection: NWConnection, buffer: Data, slot: Slot) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                slot.close()
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil || buffer.count > 64 * 1024 {
                    slot.close()
                    connection.cancel()
                    return
                }
                self.read(connection, buffer: buffer, slot: slot)
                return
            }

            let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
            let length = self.contentLength(head) ?? 0
            if length < 0 || length > 1024 {
                slot.close()
                self.send(connection, status: "400 Bad Request", body: Data("bad request".utf8))
                return
            }
            let bodyStart = range.upperBound
            if buffer.distance(from: bodyStart, to: buffer.endIndex) < length {
                if isComplete || error != nil || buffer.count > 64 * 1024 {
                    slot.close()
                    connection.cancel()
                    return
                }
                self.read(connection, buffer: buffer, slot: slot)
                return
            }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = Data(buffer[bodyStart..<bodyEnd])
            self.dispatch(head, body: body, connection: connection, slot: slot)
        }
    }

    private func dispatch(_ head: String, body: Data, connection: NWConnection, slot: Slot) {
        defer { slot.close() }
        let firstLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(connection, status: "400 Bad Request", body: Data("bad request".utf8))
            return
        }

        let method = String(parts[0])
        let (path, query) = split(String(parts[1]))
        DispatchQueue.main.async { self.hits += 1 }

        if method == "POST" && path == "/login" {
            let submitted = formFields(body)["k"] ?? ""
            finish(connection, path: "/login", verdict: auth.verify(presented: submitted), login: true)
            return
        }
        guard method == "GET" else {
            send(connection, status: "405 Method Not Allowed", body: Data("method not allowed".utf8),
                 extra: ["Allow": "GET, POST"])
            return
        }

        let verdict = auth.verify(presented: cookieJar(head)["wq"])
        if path == "/login" {
            if case .ok = verdict {
                send(connection, status: "303 See Other", body: Data(), extra: [
                    "Location": "/",
                    "Cache-Control": "no-store",
                ])
            } else {
                finish(connection, path: path, verdict: verdict, login: false)
            }
            return
        }
        guard case .ok = verdict else {
            finish(connection, path: path, verdict: verdict, login: false)
            return
        }

        let segments = path.split(separator: "/").map(String.init)
        note("200 \(path)")

        if segments.isEmpty {
            sendApps(connection)
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
                     body: Data(page("Not found", "<p>No such container.</p>", home: true).utf8))
                return
            }
            let relative = sanitize(query["p"] ?? "")
            switch segments[0] {
            case "a": sendListing(connection, container: container, relative: relative, group: group)
            case "f": sendFile(connection, container: container, relative: relative, group: group)
            default: sendZip(connection, container: container)
            }
        default:
            send(connection, status: "404 Not Found", body: Data("not found".utf8))
        }
    }

    private func finish(_ connection: NWConnection, path: String, verdict: AuthState.Verdict, login: Bool) {
        switch verdict {
        case .ok:
            note("login ok")
            send(connection, status: "303 See Other", body: Data(), extra: [
                "Location": "/",
                "Set-Cookie": sessionCookie,
                "Cache-Control": "no-store",
            ])
        case .missing:
            note("401 \(path)")
            send(connection, status: "401 Unauthorized", type: "text/html; charset=utf-8",
                 body: Data(loginPage(notice: "").utf8),
                 extra: ["Cache-Control": "no-store"])
        case .denied:
            note("401 \(path)")
            let notice = login ? "<p class=notice>Wrong password.</p>" : ""
            send(connection, status: "401 Unauthorized", type: "text/html; charset=utf-8",
                 body: Data(loginPage(notice: notice).utf8),
                 extra: ["Cache-Control": "no-store"])
        case .locked(let retry):
            note("429 \(path)")
            let notice = "<p class=notice>Too many attempts. Try again in \(retry) seconds.</p>"
            send(connection, status: "429 Too Many Requests", type: "text/html; charset=utf-8",
                 body: Data(loginPage(notice: notice).utf8),
                 extra: ["Retry-After": String(retry), "Cache-Control": "no-store"])
        }
    }

    private var sessionCookie: String {
        let token = ServerPassword.canonical(ServerPassword.current())
        return "wq=\(token); Path=/; Max-Age=86400; HttpOnly; Secure; SameSite=Strict"
    }

    // MARK: routes

    private func sendApps(_ connection: NWConnection) {
        let apps = appsProvider?() ?? []
        var rows = ""
        for app in apps {
            let icon = app.bundleID.map { "<img class=ic src=\"/i/\($0)\" loading=lazy>" }
                ?? "<div class=ic></div>"
            let subtitle = app.subtitle.addingHTMLEntities()
            rows += """
            <a class=row href="/a/\(app.container.lastPathComponent)">
              \(icon)
              <div class=t><div class=n>\(app.displayName.addingHTMLEntities())</div>
              <div class=s>\(subtitle)</div></div>
              <div class=c>›</div>
            </a>
            """
            if !app.groups.isEmpty {
                let links = app.groups.map { group in
                    "<a href=\"/a/\(group.path.lastPathComponent)\">\(group.identifier.addingHTMLEntities())</a>"
                }.joined(separator: " ")
                rows += "<div class=alt>group\(app.groups.count == 1 ? "" : "s"): \(links)</div>"
            }
            if !app.alternates.isEmpty {
                let links = app.alternates.map { path in
                    "<a href=\"/a/\(path.lastPathComponent)\">\(String(path.suffix(8)))</a>"
                }.joined(separator: " ")
                rows += "<div class=alt>+\(app.alternates.count) more container\(app.alternates.count == 1 ? "" : "s"): \(links)</div>"
            }
        }
        let body = """
        <h1>\(apps.count) apps</h1>
        <div class=list>\(rows)</div>
        """
        send(connection, status: "200 OK", type: "text/html; charset=utf-8",
             body: Data(page("Apps", body, home: true).utf8))
    }

    private func sendListing(_ connection: NWConnection, container: String, relative: String, group: String) {
        let handle = wq_grant(container, group, false)
        guard handle >= 0 else {
            send(connection, status: "500 Internal Server Error", type: "text/html; charset=utf-8",
                 body: Data(page("Denied", "<p>\(wq_last_error() ?? "no access").</p>", home: true).utf8))
            return
        }
        defer { wq_release(handle) }

        let directory = relative.isEmpty ? container : container + "/" + relative
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            send(connection, status: "404 Not Found", type: "text/html; charset=utf-8",
                 body: Data(page("Not found", "<p>No such folder.</p>", home: true).utf8))
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
        var crumbs = "<a href=\"\(link("a", identifier))\">/</a>"
        if !relative.isEmpty {
            var accumulated = ""
            for part in relative.split(separator: "/") {
                accumulated += (accumulated.isEmpty ? "" : "/") + part
                crumbs += " <a href=\"\(link("a", identifier, path: accumulated))\">\(String(part).addingHTMLEntities())</a> /"
            }
        }

        var rows = ""
        if !relative.isEmpty {
            let parent = relative.split(separator: "/").dropLast().joined(separator: "/")
            rows += "<a class=row href=\"\(link("a", identifier, path: parent))\"><div class=ic>↰</div><div class=t><div class=n>..</div></div></a>"
        }
        for (name, isFolder, size, modified) in items {
            let escaped = name.addingHTMLEntities()
            let path = relative.isEmpty ? name : relative + "/" + name
            if isFolder {
                rows += "<a class=row href=\"\(link("a", identifier, path: path))\"><div class=ic>▸</div><div class=t><div class=n>\(escaped)</div><div class=s>folder</div></div></a>"
            } else {
                rows += "<a class=row href=\"\(link("f", identifier, path: path))\"><div class=ic>≡</div><div class=t><div class=n>\(escaped)</div><div class=s>\(Fmt.bytes(size)) · \(Fmt.date(modified))</div></div><div class=c>↓</div></a>"
            }
        }

        let body = """
        <div class=crumbs>\(crumbs)</div>
        <div class=actions><a class=btn href=\"\(link("z", identifier))\">Download ZIP</a></div>
        <div class=list>\(rows)</div>
        """
        send(connection, status: "200 OK", type: "text/html; charset=utf-8",
             body: Data(page(relative.isEmpty ? identifier : (relative as NSString).lastPathComponent, body, home: true).utf8))
    }

    private func link(_ kind: String, _ identifier: String, path: String = "") -> String {
        guard !path.isEmpty else { return "/\(kind)/\(identifier)" }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "/\(kind)/\(identifier)?p=\(encoded)"
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

    private func sendZip(_ connection: NWConnection, container: String) {
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
                          body: Data(self.page("Export failed", "<p>\(error.localizedDescription)</p>", home: true).utf8))
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

    private func contentLength(_ head: String) -> Int? {
        var found: Int?
        for line in head.split(separator: "\r\n") {
            guard line.lowercased().hasPrefix("content-length:") else { continue }
            let raw = line.split(separator: ":", maxSplits: 1).dropFirst().first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let value = Int(raw), value >= 0 else { return nil }
            if found != nil { return nil }
            found = value
        }
        return found
    }

    private func formFields(_ body: Data) -> [String: String] {
        guard let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first else { continue }
            let name = String(key).removingPercentEncoding ?? String(key)
            let raw = parts.count > 1 ? String(parts[1]) : ""
            fields[name] = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        }
        return fields
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

    private func loginPage(notice: String) -> String {
        page("Locked", """
        <h1>Locked</h1>
        <p>Open the link from the Server tab, or type the password.</p>
        <div id=notice>\(notice)</div>
        <form method=post action=/login>
          <input type=password name=k placeholder="password" autocomplete=current-password autofocus>
          <button>Unlock</button>
        </form>
        <script>
        (function () {
          if (location.hash.indexOf("#k=") !== 0) return;
          var secret = decodeURIComponent(location.hash.slice(3));
          var input = document.querySelector("input[name=k]");
          if (input) input.value = secret;
          history.replaceState(null, "", location.pathname + location.search);
          var form = document.querySelector("form");
          if (form) form.submit();
        })();
        </script>
        """)
    }

    private func page(_ title: String, _ content: String, home: Bool = false) -> String {
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
        <header><b>worse_finder</b>\(home ? " · <a href=\"/\" style=\"color:#6aa8ff;text-decoration:none\">apps</a>" : "")</header>
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

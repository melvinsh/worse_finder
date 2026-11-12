//
//  TLSIdentity.swift
//  worse_finder
//
//  Self-signed P-256 certificate for the local HTTPS listener.
//  The key stays in the keychain. The certificate is re-signed with that
//  same key when a new IPv4 address has to be named.
//

import CryptoKit
import Foundation
import Network
import Security

struct TLSIdentityError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class TLSIdentity {
    /// SHA-256 of the certificate, grouped the way certificate viewers show it.
    let fingerprint: String

    private let identityRef: SecIdentity
    let secIdentity: sec_identity_t

    static func load(addresses: [String]) throws -> TLSIdentity {
        let key = try privateKey()
        let names = mergedAddresses(stored: readRecord()?.addresses ?? [], current: addresses)
        if let record = readRecord(),
           Set(record.addresses) == Set(names),
           let existing = try? TLSIdentity(der: record.der, key: key) {
            return existing
        }
        let der = try certificateDER(key: key, addresses: names)
        writeRecord(der: der, addresses: names)
        return try TLSIdentity(der: der, key: key)
    }

    func parameters() -> NWParameters {
        // sec_identity_t retains the identity, and the listener retains the
        // parameters. Keep the SecIdentity alive for the same span.
        withExtendedLifetime(identityRef) {}
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    /// DER certificate. `addresses` are IPv4 literals. `worse-finder.local` is always named.
    static func certificateDER(key: SecKey, addresses: [String], now: Date = Date()) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw TLSIdentityError(message: "no public key")
        }
        var copyError: Unmanaged<CFError>?
        guard let point = SecKeyCopyExternalRepresentation(publicKey, &copyError) as Data?,
              point.count == 65, point.first == 0x04 else {
            let detail = copyError?.takeRetainedValue().localizedDescription ?? "bad point"
            throw TLSIdentityError(message: "public key: \(detail)")
        }
        guard SecKeyIsAlgorithmSupported(key, .sign, .ecdsaSignatureMessageX962SHA256) else {
            throw TLSIdentityError(message: "key cannot sign")
        }

        var serialBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serialBytes.count, &serialBytes)
        let subject = distinguishedName("worse_finder")
        let validity = DER.sequence([
            utcTime(now.addingTimeInterval(-3600)),
            utcTime(now.addingTimeInterval(60 * 60 * 24 * 730)),
        ])
        let spki = DER.sequence([
            DER.sequence([oidEcPublicKey, oidPrime256v1]),
            DER.bitString(point),
        ])
        let extensions = DER.context(3, constructed: true, DER.sequence([
            extensionBlock(oid: oidBasicConstraints, critical: true, value: DER.sequence([])),
            extensionBlock(oid: oidKeyUsage, critical: true, value: derKeyUsage),
            extensionBlock(oid: oidExtendedKeyUsage, critical: false, value: DER.sequence([oidServerAuth])),
            extensionBlock(oid: oidSubjectAltName, critical: false, value: subjectAltName(addresses)),
        ]))
        let tbs = DER.sequence([
            DER.context(0, constructed: true, DER.integer(Data([2]))),
            DER.integer(Data(serialBytes)),
            signatureAlgorithm,
            subject,
            validity,
            subject,
            spki,
            extensions,
        ])

        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &signError) as Data? else {
            let detail = signError?.takeRetainedValue().localizedDescription ?? "unknown"
            throw TLSIdentityError(message: "sign: \(detail)")
        }
        return DER.sequence([
            tbs,
            signatureAlgorithm,
            DER.bitString(signature),
        ])
    }

    private init(der: Data, key: SecKey) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TLSIdentityError(message: "certificate rejected")
        }
        guard let identity = SecIdentityCreate(nil, certificate, key) else {
            throw TLSIdentityError(message: "identity rejected")
        }
        guard let wrapped = sec_identity_create(identity) else {
            throw TLSIdentityError(message: "tls identity rejected")
        }
        identityRef = identity
        secIdentity = wrapped
        fingerprint = Self.fingerprint(of: der)
    }

    private static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: keychain key

    private static let keyTag = Data("worse_finder.tls.key".utf8)

    private static func privateKey() throws -> SecKey {
        if let existing = loadKey() { return existing }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as [String: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw TLSIdentityError(message: "key: \(detail)")
        }
        return key
    }

    private static func loadKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecKey)
    }

    // MARK: remembered addresses

    private struct Record: Codable {
        var der: Data
        var addresses: [String]
    }

    private static let certQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "worse_finder",
        kSecAttrAccount as String: "tls-certificate",
    ]

    /// Loopback, then current addresses, then older ones, capped at eight.
    private static func mergedAddresses(stored: [String], current: [String]) -> [String] {
        var list: [String] = []
        func append(_ address: String) {
            guard ipv4(address) != nil, !list.contains(address) else { return }
            list.append(address)
        }
        append("127.0.0.1")
        for address in current { append(address) }
        if list.count > 8 { return Array(list.prefix(8)) }
        for address in stored {
            if list.count >= 8 { break }
            append(address)
        }
        return list
    }

    private static func readRecord() -> Record? {
        var query = certQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return record
    }

    private static func writeRecord(der: Data, addresses: [String]) {
        let data = (try? JSONEncoder().encode(Record(der: der, addresses: addresses))) ?? Data()
        SecItemDelete(certQuery as CFDictionary)
        var add = certQuery
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: name

    private static func subjectAltName(_ addresses: [String]) -> Data {
        var names = [DER.context(2, constructed: false, Data("worse-finder.local".utf8))]
        for address in addresses {
            guard let bytes = ipv4(address) else { continue }
            names.append(DER.context(7, constructed: false, bytes))
        }
        return DER.sequence(names)
    }

    private static func ipv4(_ text: String) -> Data? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes = Data()
        for part in parts {
            guard let value = UInt8(part), String(value) == part else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    private static func distinguishedName(_ commonName: String) -> Data {
        let attribute = DER.sequence([oidCommonName, DER.utf8(commonName)])
        return DER.sequence([DER.tl(0x31, attribute)])
    }

    private static func extensionBlock(oid: Data, critical: Bool, value: Data) -> Data {
        var parts = [oid]
        if critical { parts.append(DER.boolean(true)) }
        parts.append(DER.octetString(value))
        return DER.sequence(parts)
    }

    private static func utcTime(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(format: "%02d%02d%02d%02d%02d%02dZ",
                          (parts.year ?? 0) % 100,
                          parts.month ?? 0,
                          parts.day ?? 0,
                          parts.hour ?? 0,
                          parts.minute ?? 0,
                          parts.second ?? 0)
        return DER.tl(0x17, Data(text.utf8))
    }

    // MARK: OIDs

    /// digitalSignature (bit 0), unused bits in the trailing byte = 7.
    private static let derKeyUsage = Data([0x03, 0x02, 0x07, 0x80])

    private static let signatureAlgorithm = DER.sequence([oidEcdsaWithSHA256])

    private static let oidCommonName = DER.oid([0x55, 0x04, 0x03])
    private static let oidEcPublicKey = DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
    private static let oidPrime256v1 = DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
    private static let oidEcdsaWithSHA256 = DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    private static let oidBasicConstraints = DER.oid([0x55, 0x1D, 0x13])
    private static let oidKeyUsage = DER.oid([0x55, 0x1D, 0x0F])
    private static let oidSubjectAltName = DER.oid([0x55, 0x1D, 0x11])
    private static let oidExtendedKeyUsage = DER.oid([0x55, 0x1D, 0x25])
    private static let oidServerAuth = DER.oid([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])
}

private enum DER {
    static func tl(_ tag: UInt8, _ body: Data) -> Data {
        var out = Data([tag])
        out.append(length(body.count))
        out.append(body)
        return out
    }

    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        if count <= 0xFF { return Data([0x81, UInt8(count)]) }
        return Data([0x82, UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)])
    }

    static func sequence(_ parts: [Data]) -> Data {
        tl(0x30, parts.reduce(into: Data()) { $0.append($1) })
    }

    static func integer(_ bytes: Data) -> Data {
        var body = bytes.isEmpty ? Data([0]) : bytes
        if body[body.startIndex] >= 0x80 { body.insert(0, at: body.startIndex) }
        while body.count > 1 && body[body.startIndex] == 0 && body[body.index(after: body.startIndex)] < 0x80 {
            body.removeFirst()
        }
        return tl(0x02, body)
    }

    static func bitString(_ payload: Data) -> Data {
        tl(0x03, Data([0x00]) + payload)
    }

    static func oid(_ body: [UInt8]) -> Data { tl(0x06, Data(body)) }
    static func utf8(_ text: String) -> Data { tl(0x0C, Data(text.utf8)) }
    static func octetString(_ body: Data) -> Data { tl(0x04, body) }
    static func boolean(_ value: Bool) -> Data { tl(0x01, Data([value ? 0xFF : 0x00])) }

    static func context(_ number: UInt8, constructed: Bool, _ body: Data) -> Data {
        let tag = UInt8(0x80 | (constructed ? 0x20 : 0) | number)
        return tl(tag, body)
    }
}

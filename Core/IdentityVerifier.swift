import Foundation
import CryptoKit
import Security

struct Identity: Decodable {
    let iss: String
    let sub: String
    let exp: Double
    let iat: Double
    let nbf: Double?
    let nonce: String?
    let email: String?
    let azp: String?
    let aud: Audience
    enum Audience: Decodable {
        case one(String), many([String])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .one(s) }
            else { self = .many(try c.decode([String].self)) }
        }
        var values: [String] { switch self { case .one(let s): return [s]; case .many(let s): return s } }
    }
}

struct OpenIDMetadata: Decodable {
    let issuer: String
    let authorization_endpoint: URL
    let token_endpoint: URL
    let jwks_uri: URL
    let revocation_endpoint: URL?

    static func load() async throws -> OpenIDMetadata {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
        request.timeoutInterval = 15
        let (data, response) = try await HTTP.session.data(for: request)
        try HTTP.check(response)
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.issuer == "https://auth.openai.com" else { throw AppFailure.message("登录服务的发行者无效。") }
        for url in [value.authorization_endpoint, value.token_endpoint, value.jwks_uri] + [value.revocation_endpoint].compactMap({ $0 }) {
            guard url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443 else { throw AppFailure.message("登录服务地址未通过验证。") }
        }
        return value
    }
}

enum IdentityVerifier {
    private struct Header: Decodable { let alg: String; let kid: String; let crit: [String]? }
    private struct Keys: Decodable { let keys: [JWK] }
    private struct JWK: Decodable {
        let kid: String?
        let kty: String
        let alg: String?
        let use: String?
        let key_ops: [String]?
        let n: String?
        let e: String?
        let crv: String?
        let x: String?
        let y: String?
    }

    // A deliberately narrow verifier: RS256 and ES256 only. Unknown algorithms fail closed.
    // It never follows an untrusted jku/x5u URL from the JWT header.
    static func verify(_ jwt: String, clientID: String, nonce: String?, metadata: OpenIDMetadata) async throws -> Identity {
        let (data, response) = try await HTTP.session.data(from: metadata.jwks_uri)
        try HTTP.check(response)
        return try verify(jwt, clientID: clientID, nonce: nonce, metadata: metadata, jwks: data)
    }

    static func verify(_ jwt: String, clientID: String, nonce: String?, metadata: OpenIDMetadata, jwks: Data) throws -> Identity {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, jwt.utf8.count < 65536 else { throw invalid() }
        let header = try JSONDecoder().decode(Header.self, from: EncodingTools.decodeBase64URL(parts[0]))
        guard ["RS256", "ES256"].contains(header.alg), header.crit?.isEmpty != false else { throw invalid() }
        let candidates = try JSONDecoder().decode(Keys.self, from: jwks).keys.filter {
            $0.kid == header.kid && ($0.alg == nil || $0.alg == header.alg) && ($0.use == nil || $0.use == "sig")
                && ($0.key_ops == nil || $0.key_ops!.contains("verify"))
        }
        guard candidates.count == 1, let key = candidates.first else { throw invalid() }
        let message = Data((parts[0] + "." + parts[1]).utf8)
        let signature = try EncodingTools.decodeBase64URL(parts[2])
        if header.alg == "RS256" {
            guard key.kty == "RSA", let n = key.n, let e = key.e else { throw invalid() }
            let modulus = try EncodingTools.decodeBase64URL(n)
            let exponent = try EncodingTools.decodeBase64URL(e)
            guard modulus.count >= 256, modulus.count <= 1024 else { throw invalid() }
            let der = wrap(0x30, integer(modulus) + integer(exponent))
            let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                       kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
            guard let publicKey = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil),
                  SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil) else { throw invalid() }
        } else {
            guard key.kty == "EC", key.crv == "P-256", let x = key.x, let y = key.y else { throw invalid() }
            let pointX = try EncodingTools.decodeBase64URL(x), pointY = try EncodingTools.decodeBase64URL(y)
            guard pointX.count == 32, pointY.count == 32 else { throw invalid() }
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + pointX + pointY)
            guard try publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: signature), for: message) else { throw invalid() }
        }
        let identity = try JSONDecoder().decode(Identity.self, from: EncodingTools.decodeBase64URL(parts[1]))
        let now = Date().timeIntervalSince1970
        guard identity.iss == metadata.issuer, !identity.sub.isEmpty,
              identity.aud.values.contains(clientID), identity.exp > now - 5,
              identity.iat <= now + 5, identity.iat <= identity.exp,
              identity.nbf.map({ $0 <= now + 5 }) ?? true else { throw invalid() }
        if identity.aud.values.count > 1, identity.azp != clientID { throw invalid() }
        if let azp = identity.azp, azp != clientID { throw invalid() }
        if let nonce = nonce, identity.nonce != nonce { throw invalid() }
        return identity
    }
    private static func invalid() -> AppFailure { .message("身份验证未通过。请重新连接 ChatGPT。") }
    private static func integer(_ bytes: Data) -> Data {
        var body = Data(bytes.drop(while: { $0 == 0 }))
        if body.isEmpty { body = Data([0]) }
        if body.first! & 0x80 != 0 { body.insert(0, at: 0) }
        return wrap(0x02, body)
    }
    private static func wrap(_ tag: UInt8, _ body: Data) -> Data {
        var length = body.count
        var encoded: [UInt8] = []
        if length < 128 { encoded = [UInt8(length)] }
        else {
            while length > 0 { encoded.insert(UInt8(length & 0xff), at: 0); length >>= 8 }
            encoded.insert(0x80 | UInt8(encoded.count), at: 0)
        }
        return Data([tag] + encoded) + body
    }
}

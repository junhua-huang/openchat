import AuthenticationServices
import CryptoKit
import Foundation
import Security

// Synthetic, in-memory dependencies only. Never presents native authorization UI,
// writes real Keychain items, or contacts Apple, ChatGPT or API services.
@main struct AppleSignInChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); count += 1
        }
        func rejects(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(message) } catch { count += 1 }
        }
        func identity(_ user: String = "user-a", email: String? = "relay@privaterelay.appleid.com") -> Identity {
            Identity(iss: "https://appleid.apple.com", sub: user, exp: Date().timeIntervalSince1970 + 600,
                     iat: Date().timeIntervalSince1970, nbf: nil, nonce: nil, email: email, azp: nil,
                     aud: .one("synthetic.app"))
        }
        let original = AppleAccount(userID: "user-a", fullName: "测试用户", email: "relay@privaterelay.appleid.com")
        let repeated = try AppleAccount.updated(userID: "user-a", fullName: "  ", email: nil, previous: original)
        check(repeated == original, "Repeat authorization must preserve first-only fields")
        let different = try AppleAccount.updated(userID: "user-b", fullName: nil, email: nil, previous: original)
        check(different.fullName == nil && different.email == nil, "Never reuse another Apple user's personal details")
        check(different.displayName == "Apple 账户", "Missing optional details need a usable fallback")
        rejects("Empty subject must fail") { _ = try AppleAccount.updated(userID: "", fullName: nil, email: nil, previous: nil) }
        let decoded = try JSONDecoder().decode(AppleAccount.self, from: JSONEncoder().encode(original))
        check(decoded == original,
              "Identity must round-trip without authorization tokens")

        var saved: AppleAccount?
        var writes = 0
        var verifications = 0
        let manager = AppleSignInManager(load: { saved }, save: { saved = $0; writes += 1 }, remove: { saved = nil },
            credentialState: { _ in .authorized }, verify: { token, nonce in
                check(token == "synthetic-token" && !nonce.isEmpty, "Pass the actual request nonce to signature validation")
                verifications += 1; return identity()
            })
        check(manager.storageReady && manager.account == nil, "Fresh install remains usable without Apple login")
        let first = try manager.beginSignIn()
        check(first.nonce != first.state && first.nonce.count >= 32, "Use separate cryptographically random state and nonce")
        rejects("Concurrent authorization must fail") { _ = try manager.beginSignIn() }
        let success = AppleSignInResult(userID: "user-a", state: first.state, identityToken: "synthetic-token", fullName: "测试用户", email: nil)
        await manager.complete(success, attemptID: first.id)
        check(manager.account == original && manager.sessionState == .signedIn && !manager.isBusy, "Valid sign-in must persist and finish")
        await manager.complete(success, attemptID: first.id)
        check(writes == 1 && verifications == 1, "Duplicate completion must not replay verification or writes")

        let badState = try manager.beginSignIn()
        await manager.complete(AppleSignInResult(userID: "user-a", state: "wrong", identityToken: "synthetic-token", fullName: nil, email: nil), attemptID: badState.id)
        check(writes == 1 && verifications == 1 && manager.notice != nil, "State mismatch must fail before token validation")
        check(manager.account == original, "Failed reauthentication must preserve the prior identity")
        let canceled = try manager.beginSignIn()
        manager.cancelSignIn(attemptID: canceled.id, error: NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.canceled.rawValue))
        check(!manager.isBusy && manager.notice == nil, "User cancellation must be quiet")
        let replacement = try manager.beginSignIn()
        await manager.complete(success, attemptID: canceled.id)
        check(manager.isBusy && writes == 1, "Old callbacks must not cancel or save over a newer attempt")
        manager.cancelSignIn(attemptID: replacement.id)
        manager.signOut()
        check(manager.account == nil && saved == nil && manager.sessionState == .signedOut, "Sign-out must remove only the local Apple identity")

        let mismatched = AppleSignInManager(load: { nil }, save: { _ in writes += 1 }, remove: {},
            credentialState: { _ in .authorized }, verify: { _, _ in identity("other-user") })
        let mismatch = try mismatched.beginSignIn()
        await mismatched.complete(AppleSignInResult(userID: "user-a", state: mismatch.state, identityToken: "synthetic-token", fullName: nil, email: nil), attemptID: mismatch.id)
        check(mismatched.account == nil && writes == 1, "Credential subject must match the signed token subject")
        let invalid = AppleSignInManager(load: { nil }, save: { _ in writes += 1 }, remove: {},
            credentialState: { _ in .authorized }, verify: { _, _ in throw AppFailure.message("invalid signature") })
        let badToken = try invalid.beginSignIn()
        await invalid.complete(AppleSignInResult(userID: "user-a", state: badToken.state, identityToken: "bad-token", fullName: nil, email: nil), attemptID: badToken.id)
        check(invalid.account == nil && !invalid.isBusy && writes == 1, "Invalid tokens must never create an identity")

        let locked = AppleSignInManager(load: { throw AppFailure.message("locked") }, save: { _ in writes += 1 }, remove: {},
            credentialState: { _ in .authorized }, verify: { _, _ in identity() })
        check(!locked.storageReady && locked.account == nil, "Keychain read errors must not overwrite existing identity")
        rejects("Storage failure must block sign-in writes") { _ = try locked.beginSignIn() }
        let unwritable = AppleSignInManager(load: { nil }, save: { _ in throw AppFailure.message("locked") }, remove: {},
            credentialState: { _ in .authorized }, verify: { _, _ in identity() })
        let failedSave = try unwritable.beginSignIn()
        await unwritable.complete(AppleSignInResult(userID: "user-a", state: failedSave.state, identityToken: "synthetic-token", fullName: nil, email: nil), attemptID: failedSave.id)
        check(unwritable.account == nil && unwritable.notice != nil && !unwritable.isBusy, "Failed persistence must not report successful login")

        for state in [ASAuthorizationAppleIDProvider.CredentialState.authorized, .revoked, .notFound, .transferred] {
            var stored: AppleAccount? = original
            let restored = AppleSignInManager(load: { stored }, save: { stored = $0 }, remove: { stored = nil },
                credentialState: { _ in state }, verify: { _, _ in identity() })
            check(restored.sessionState == .checking, "Restored identity must be rechecked")
            await restored.refreshCredentialState()
            check((restored.account != nil) == (state == .authorized), "Invalid and transferred credentials must end the local session")
            check((stored != nil) == (state == .authorized), "Revocation must also remove persistent identity")
        }
        let offline = AppleSignInManager(load: { original }, save: { _ in }, remove: {},
            credentialState: { _ in throw URLError(.notConnectedToInternet) }, verify: { _, _ in identity() })
        await offline.refreshCredentialState()
        check(offline.account == original && offline.sessionState == .unavailable, "Temporary state-check failure must preserve saved data without claiming validation")
        offline.credentialWasRevoked()
        check(offline.account == nil && offline.sessionState == .signedOut, "Revocation notification must invalidate identity immediately")

        // Suspend verification, sign out, then deliver the old result. It must not
        // silently sign the user back in after a sign-out or revocation.
        var resume: CheckedContinuation<Identity, Never>?
        let delayed = AppleSignInManager(load: { nil }, save: { _ in writes += 1 }, remove: {},
            credentialState: { _ in .authorized }, verify: { _, _ in
                await withCheckedContinuation { resume = $0 }
            })
        let late = try delayed.beginSignIn()
        let task = Task { await delayed.complete(AppleSignInResult(userID: "user-a", state: late.state, identityToken: "synthetic-token", fullName: nil, email: nil), attemptID: late.id) }
        for _ in 0..<1000 { if resume != nil { break }; await Task.yield() }
        guard let resume = resume else { preconditionFailure("Verification did not start") }
        delayed.signOut()
        resume.resume(returning: identity())
        await task.value
        check(delayed.account == nil && writes == 1, "Late verification must not undo sign-out")

        var resumeState: CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState, Never>?
        let stale = AppleSignInManager(load: { original }, save: { _ in }, remove: {},
            credentialState: { _ in await withCheckedContinuation { resumeState = $0 } }, verify: { _, _ in identity() })
        let checking = Task { await stale.refreshCredentialState() }
        for _ in 0..<1000 { if resumeState != nil { break }; await Task.yield() }
        guard let resumeState = resumeState else { preconditionFailure("Credential check did not start") }
        let current = try stale.beginSignIn()
        await stale.complete(AppleSignInResult(userID: "user-a", state: current.state, identityToken: "synthetic-token", fullName: nil, email: nil), attemptID: current.id)
        resumeState.resume(returning: .revoked)
        await checking.value
        check(stale.account == original && stale.sessionState == .signedIn, "Old credential checks must not revoke a newly completed sign-in")

        // Verify real synthetic signatures through the production JWT verifier,
        // using only public test keys generated in memory and fixed Apple URLs.
        let privateKey = P256.Signing.PrivateKey()
        let point = privateKey.publicKey.x963Representation
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "synthetic", "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig",
            "x": EncodingTools.base64URL(Data(point[1..<33])), "y": EncodingTools.base64URL(Data(point[33..<65]))]]])
        let metadata = OpenIDMetadata(issuer: "https://appleid.apple.com", authorization_endpoint: URL(string: "https://appleid.apple.com/auth/authorize")!,
            token_endpoint: URL(string: "https://appleid.apple.com/auth/token")!, jwks_uri: URL(string: "https://appleid.apple.com/auth/keys")!, revocation_endpoint: nil)
        let now = Date().timeIntervalSince1970
        let claims: [String: Any] = ["iss": "https://appleid.apple.com", "sub": "user-a", "aud": "synthetic.app", "iat": now, "exp": now + 600, "nonce": "expected"]
        func token(_ claims: [String: Any]) throws -> String {
            let header = EncodingTools.base64URL(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "synthetic"]))
            let body = EncodingTools.base64URL(try JSONSerialization.data(withJSONObject: claims))
            let message = header + "." + body
            return message + "." + EncodingTools.base64URL(try privateKey.signature(for: Data(message.utf8)).rawRepresentation)
        }
        let signed = try token(claims)
        let valid = try IdentityVerifier.verify(signed, clientID: "synthetic.app", nonce: "expected", metadata: metadata, jwks: jwks)
        check(valid.sub == "user-a", "Validate Apple issuer, bundle audience, nonce and signature")
        let invalidClaims: [(String, Any)] = [("iss", "https://other.invalid"), ("aud", "wrong.app"), ("nonce", "wrong"), ("exp", now - 60), ("iat", now + 120)]
        for (key, value) in invalidClaims {
            var changed = claims; changed[key] = value
            rejects("Reject invalid \(key)") { _ = try IdentityVerifier.verify(token(changed), clientID: "synthetic.app", nonce: "expected", metadata: metadata, jwks: jwks) }
        }
        let parts = signed.split(separator: ".").map(String.init)
        let tampered = parts[0] + "." + EncodingTools.base64URL(Data("{}".utf8)) + "." + parts[2]
        rejects("Reject tampered token") { _ = try IdentityVerifier.verify(tampered, clientID: "synthetic.app", nonce: "expected", metadata: metadata, jwks: jwks) }
        print("Passed \(count) Apple sign-in host checks (no app, device, simulator or network).")
    }
}

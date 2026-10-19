import Foundation

/// Local app identity only. Never a ChatGPT/API credential or a model prompt field.
struct AppleAccount: Codable, Equatable {
    let userID: String
    let fullName: String?
    let email: String?

    var displayName: String { fullName ?? email ?? "Apple 账户" }

    static func updated(userID: String, fullName: String?, email: String?, previous: AppleAccount?) throws -> AppleAccount {
        guard !userID.isEmpty else { throw AppFailure.message("Apple 登录没有返回有效身份，请重试。") }
        let prior = previous?.userID == userID ? previous : nil
        // Apple supplies name/email on the first authorization only. Do not erase them
        // on subsequent sign-ins, or carry them across different Apple users.
        func clean(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        return AppleAccount(userID: userID, fullName: clean(fullName) ?? prior?.fullName,
                            email: clean(email) ?? prior?.email)
    }
}

struct AppleSignInAttempt: Equatable {
    let id: UUID
    let state: String
    let nonce: String
}

struct AppleSignInResult {
    let userID: String
    let state: String?
    let identityToken: String
    let fullName: String?
    let email: String?
}

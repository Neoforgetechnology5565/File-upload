import Foundation

/// On-device email/password accounts.
///
/// - Credentials: PBKDF2-HMAC-SHA256 hash + random salt, stored in the
///   Keychain (`SecureStore`). The plain password is never persisted.
/// - Session: the signed-in account's email in the Keychain.
/// - Brute force: progressive lockout after repeated failures.
///
/// This gives a complete, secure sign-in/sign-out/profile flow without any
/// backend. Swap in `RESTAuthService` (or another `AuthService`) for real
/// cloud accounts.
actor LocalAuthService: AuthService {
    private struct StoredAccount: Codable {
        var profile: UserProfile
        var password: PasswordHash
    }

    nonisolated let providerName = "Account stored on this device"

    private let store: SecureStore
    private let defaults: UserDefaults
    private let iterations: UInt32
    private var failedAttempts = 0
    private var lockedUntil: Date?

    private static let sessionKey = "session.current"
    private static let guestKey = "auth.guestMode"

    init(store: SecureStore, defaults: UserDefaults = .standard, iterations: UInt32 = PasswordHasher.defaultIterations) {
        self.store = store
        self.defaults = defaults
        self.iterations = iterations
    }

    func restoreSession() async -> AuthState {
        if let emailData = try? store.data(for: Self.sessionKey),
           let email = String(data: emailData, encoding: .utf8),
           let account = try? loadAccount(email: email) {
            return .signedIn(account.profile)
        }
        return defaults.bool(forKey: Self.guestKey) ? .guest : .signedOut
    }

    func signIn(email: String, password: String) async throws -> UserProfile {
        try checkLockout()
        let normalized = CredentialValidator.normalizedEmail(email)
        guard let account = try loadAccount(email: normalized),
              (try? PasswordHasher.verify(password, against: account.password)) == true else {
            registerFailure()
            throw AuthError.invalidCredentials
        }
        failedAttempts = 0
        lockedUntil = nil
        try startSession(email: normalized)
        return account.profile
    }

    func register(email: String, password: String, displayName: String) async throws -> UserProfile {
        let normalized = try CredentialValidator.validateEmail(email)
        try CredentialValidator.validatePassword(password)
        let name = try CredentialValidator.validateDisplayName(displayName)
        guard try loadAccount(email: normalized) == nil else { throw AuthError.accountExists }

        let profile = UserProfile(id: UUID().uuidString, email: normalized, displayName: name, createdAt: Date())
        let hash = try PasswordHasher.hash(password, iterations: iterations)
        try saveAccount(StoredAccount(profile: profile, password: hash))
        try startSession(email: normalized)
        return profile
    }

    func signOut() async throws {
        try store.remove(Self.sessionKey)
        defaults.set(false, forKey: Self.guestKey)
    }

    func continueAsGuest() async {
        try? store.remove(Self.sessionKey)
        defaults.set(true, forKey: Self.guestKey)
    }

    func updateProfile(displayName: String) async throws -> UserProfile {
        var account = try currentAccount()
        account.profile.displayName = try CredentialValidator.validateDisplayName(displayName)
        try saveAccount(account)
        return account.profile
    }

    func deleteAccount() async throws {
        let account = try currentAccount()
        try store.remove(Self.accountKey(account.profile.email))
        try store.remove(Self.sessionKey)
        defaults.set(false, forKey: Self.guestKey)
    }

    // MARK: Helpers

    private static func accountKey(_ email: String) -> String { "account.\(email)" }

    private func loadAccount(email: String) throws -> StoredAccount? {
        guard let data = try store.data(for: Self.accountKey(email)) else { return nil }
        return try JSONDecoder().decode(StoredAccount.self, from: data)
    }

    private func saveAccount(_ account: StoredAccount) throws {
        let data = try JSONEncoder().encode(account)
        try store.set(data, for: Self.accountKey(account.profile.email))
    }

    private func currentAccount() throws -> StoredAccount {
        guard let data = try store.data(for: Self.sessionKey),
              let email = String(data: data, encoding: .utf8),
              let account = try loadAccount(email: email) else {
            throw AuthError.notSignedIn
        }
        return account
    }

    private func startSession(email: String) throws {
        try store.set(Data(email.utf8), for: Self.sessionKey)
        defaults.set(false, forKey: Self.guestKey)
    }

    private func checkLockout() throws {
        if let lockedUntil, lockedUntil > Date() {
            throw AuthError.tooManyAttempts(retryAfter: Int(lockedUntil.timeIntervalSinceNow.rounded(.up)))
        }
    }

    private func registerFailure() {
        failedAttempts += 1
        if failedAttempts >= 5 {
            // 30 s, 60 s, 120 s … capped at 15 minutes.
            let seconds = min(30 * pow(2, Double(failedAttempts - 5)), 900)
            lockedUntil = Date().addingTimeInterval(seconds)
        }
    }
}

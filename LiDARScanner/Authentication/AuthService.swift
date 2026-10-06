import Foundation

struct UserProfile: Codable, Equatable, Sendable {
    var id: String
    var email: String
    var displayName: String
    var createdAt: Date
}

enum AuthState: Equatable, Sendable {
    case unknown
    case signedOut
    /// Using the app locally without an account.
    case guest
    case signedIn(UserProfile)

    var user: UserProfile? {
        if case .signedIn(let user) = self { return user }
        return nil
    }

    var canUseApp: Bool {
        switch self {
        case .guest, .signedIn: return true
        case .unknown, .signedOut: return false
        }
    }
}

enum AuthError: Error, LocalizedError, Equatable {
    case invalidEmail
    case weakPassword(String)
    case passwordsDoNotMatch
    case invalidCredentials
    case accountExists
    case notSignedIn
    case tooManyAttempts(retryAfter: Int)
    case backendNotConfigured
    case network(String)
    case server(String)
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail: return "Enter a valid email address."
        case .weakPassword(let reason): return reason
        case .passwordsDoNotMatch: return "Passwords do not match."
        case .invalidCredentials: return "The email or password is incorrect."
        case .accountExists: return "An account with this email already exists."
        case .notSignedIn: return "You are not signed in."
        case .tooManyAttempts(let seconds): return "Too many attempts. Try again in \(seconds) seconds."
        case .backendNotConfigured: return "Account sign-in is not configured for this build."
        case .network(let reason): return "Network error: \(reason)"
        case .server(let reason): return "Server error: \(reason)"
        case .storage(let reason): return "Secure storage error: \(reason)"
        }
    }
}

/// Authentication abstraction. The scanning engine never depends on this.
///
/// Implementations:
/// - `LocalAuthService`: on-device accounts (PBKDF2 password hashes in the Keychain).
/// - `RESTAuthService`: a generic token-based HTTP backend, enabled when
///   `LSBackendBaseURL` is set in Info.plist (see Docs/BACKEND_INTEGRATION.md).
/// Firebase/Supabase/Cognito adapters can be added by conforming to this protocol.
protocol AuthService: Sendable {
    /// Human-readable description of where accounts live.
    var providerName: String { get }
    func restoreSession() async -> AuthState
    func signIn(email: String, password: String) async throws -> UserProfile
    func register(email: String, password: String, displayName: String) async throws -> UserProfile
    func signOut() async throws
    func continueAsGuest() async
    func updateProfile(displayName: String) async throws -> UserProfile
    func deleteAccount() async throws
}

/// Input validation shared by all auth implementations and the UI.
enum CredentialValidator {
    static func normalizedEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func validateEmail(_ raw: String) throws -> String {
        let email = normalizedEmail(raw)
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        guard email.count <= 254, email.range(of: pattern, options: .regularExpression) != nil else {
            throw AuthError.invalidEmail
        }
        return email
    }

    static func validatePassword(_ password: String) throws {
        guard password.count >= 8 else { throw AuthError.weakPassword("Use at least 8 characters.") }
        guard password.count <= 128 else { throw AuthError.weakPassword("Use at most 128 characters.") }
        guard password.rangeOfCharacter(from: .letters) != nil,
              password.rangeOfCharacter(from: .decimalDigits) != nil else {
            throw AuthError.weakPassword("Use at least one letter and one number.")
        }
    }

    static func validateDisplayName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else {
            throw AuthError.server("Enter a name between 1 and 60 characters.")
        }
        return name
    }
}

import Foundation

/// CONFIGURATION POINT — backend settings, read from Info.plist.
///
/// Set `LSBackendBaseURL` (e.g. `https://api.example.com/v1`) in the target's
/// Info.plist (or via the `LS_BACKEND_BASE_URL` build setting) to enable
/// `RESTAuthService`. When empty, the app uses on-device accounts.
struct BackendConfiguration: Equatable, Sendable {
    var baseURL: URL

    static func fromBundle(_ bundle: Bundle = .main) -> BackendConfiguration? {
        guard let raw = bundle.object(forInfoDictionaryKey: "LSBackendBaseURL") as? String,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty,
              let url = URL(string: raw),
              url.scheme == "https" else {
            return nil
        }
        return BackendConfiguration(baseURL: url)
    }
}

/// Generic token-based HTTP authentication.
///
/// Expected API contract (documented in Docs/BACKEND_INTEGRATION.md):
/// ```
/// POST   /auth/register  {email, password, displayName} → {accessToken, user}
/// POST   /auth/login     {email, password}              → {accessToken, user}
/// GET    /auth/me        (Bearer)                       → user
/// PATCH  /auth/me        {displayName} (Bearer)         → user
/// POST   /auth/logout    (Bearer)                       → 204
/// DELETE /auth/me        (Bearer)                       → 204
/// user = {id, email, displayName, createdAt (ISO-8601)}
/// ```
/// The access token is stored in the Keychain; passwords are only sent over
/// HTTPS and never stored.
actor RESTAuthService: AuthService {
    private struct AuthResponse: Decodable {
        var accessToken: String
        var user: UserProfile
    }

    nonisolated let providerName: String

    private let configuration: BackendConfiguration
    private let session: URLSession
    private let store: SecureStore
    private let defaults: UserDefaults
    private static let tokenKey = "rest.accessToken"
    private static let profileKey = "rest.profile"
    private static let guestKey = "auth.guestMode"

    init(configuration: BackendConfiguration, store: SecureStore, session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.store = store
        self.session = session
        self.defaults = defaults
        self.providerName = "Cloud account (\(configuration.baseURL.host ?? "server"))"
    }

    func restoreSession() async -> AuthState {
        guard (try? store.data(for: Self.tokenKey)) != nil else {
            return defaults.bool(forKey: Self.guestKey) ? .guest : .signedOut
        }
        do {
            let user: UserProfile = try await request("auth/me", method: "GET", body: Optional<String>.none, authorized: true)
            try cache(user)
            return .signedIn(user)
        } catch AuthError.notSignedIn {
            try? clearSession()
            return .signedOut
        } catch {
            // Offline: keep the cached profile so local scans stay usable.
            if let data = try? store.data(for: Self.profileKey), let user = try? decoder.decode(UserProfile.self, from: data) {
                return .signedIn(user)
            }
            return .signedOut
        }
    }

    func signIn(email: String, password: String) async throws -> UserProfile {
        let normalized = try CredentialValidator.validateEmail(email)
        let response: AuthResponse = try await request("auth/login", method: "POST", body: ["email": normalized, "password": password], authorized: false)
        try persist(response)
        return response.user
    }

    func register(email: String, password: String, displayName: String) async throws -> UserProfile {
        let normalized = try CredentialValidator.validateEmail(email)
        try CredentialValidator.validatePassword(password)
        let name = try CredentialValidator.validateDisplayName(displayName)
        let response: AuthResponse = try await request(
            "auth/register",
            method: "POST",
            body: ["email": normalized, "password": password, "displayName": name],
            authorized: false
        )
        try persist(response)
        return response.user
    }

    func signOut() async throws {
        _ = try? await requestNoContent("auth/logout", method: "POST")
        try clearSession()
        defaults.set(false, forKey: Self.guestKey)
    }

    func continueAsGuest() async {
        try? clearSession()
        defaults.set(true, forKey: Self.guestKey)
    }

    func updateProfile(displayName: String) async throws -> UserProfile {
        let name = try CredentialValidator.validateDisplayName(displayName)
        let user: UserProfile = try await request("auth/me", method: "PATCH", body: ["displayName": name], authorized: true)
        try cache(user)
        return user
    }

    func deleteAccount() async throws {
        try await requestNoContent("auth/me", method: "DELETE")
        try clearSession()
    }

    // MARK: Networking

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeRequest(_ path: String, method: String, body: Data?, authorized: Bool) throws -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized {
            guard let tokenData = try store.data(for: Self.tokenKey), let token = String(data: tokenData, encoding: .utf8) else {
                throw AuthError.notSignedIn
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func request<Body: Encodable, Response: Decodable>(_ path: String, method: String, body: Body?, authorized: Bool) async throws -> Response {
        let bodyData = try body.map { try JSONEncoder().encode($0) }
        let data = try await perform(makeRequest(path, method: method, body: bodyData, authorized: authorized))
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw AuthError.server("Unexpected response from server.")
        }
    }

    private func requestNoContent(_ path: String, method: String) async throws {
        _ = try await perform(makeRequest(path, method: method, body: nil, authorized: true))
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw AuthError.network(error.localizedDescription)
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw AuthError.server("Invalid response.") }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw request.value(forHTTPHeaderField: "Authorization") == nil ? AuthError.invalidCredentials : AuthError.notSignedIn
        case 409: throw AuthError.accountExists
        case 429: throw AuthError.tooManyAttempts(retryAfter: Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60)
        default: throw AuthError.server("HTTP \(http.statusCode)")
        }
    }

    private func persist(_ response: AuthResponse) throws {
        try store.set(Data(response.accessToken.utf8), for: Self.tokenKey)
        try cache(response.user)
        defaults.set(false, forKey: Self.guestKey)
    }

    private func cache(_ user: UserProfile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try store.set(encoder.encode(user), for: Self.profileKey)
    }

    private func clearSession() throws {
        try store.remove(Self.tokenKey)
        try store.remove(Self.profileKey)
    }
}

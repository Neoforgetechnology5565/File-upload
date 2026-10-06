import Foundation
import Observation

@Observable
@MainActor
final class AuthViewModel {
    var email = ""
    var password = ""
    var confirmPassword = ""
    var displayName = ""
    private(set) var isWorking = false
    var error: AppError?

    private let authService: AuthService

    init(authService: AuthService) {
        self.authService = authService
    }

    var providerName: String { authService.providerName }

    var canSignIn: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isWorking
    }

    var canRegister: Bool {
        !email.isEmpty && !password.isEmpty && !confirmPassword.isEmpty && !displayName.isEmpty && !isWorking
    }

    /// Inline password guidance shown while typing (nil when acceptable).
    var passwordHint: String? {
        guard !password.isEmpty else { return nil }
        do {
            try CredentialValidator.validatePassword(password)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func signIn() async -> AuthState? {
        await perform {
            let user = try await self.authService.signIn(email: self.email, password: self.password)
            return .signedIn(user)
        }
    }

    func register() async -> AuthState? {
        guard password == confirmPassword else {
            error = .authenticationFailed(AuthError.passwordsDoNotMatch.localizedDescription)
            return nil
        }
        return await perform {
            let user = try await self.authService.register(email: self.email, password: self.password, displayName: self.displayName)
            return .signedIn(user)
        }
    }

    func continueAsGuest() async -> AuthState {
        await authService.continueAsGuest()
        return .guest
    }

    private func perform(_ operation: () async throws -> AuthState) async -> AuthState? {
        isWorking = true
        defer { isWorking = false }
        do {
            let state = try await operation()
            password = ""
            confirmPassword = ""
            return state
        } catch {
            self.error = AppError.from(error)
            return nil
        }
    }
}

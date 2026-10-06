import XCTest
@testable import LiDARScanner

final class CredentialValidatorTests: XCTestCase {
    func testEmailValidationAndNormalization() throws {
        XCTAssertEqual(try CredentialValidator.validateEmail("  Ada@Example.COM "), "ada@example.com")
        XCTAssertThrowsError(try CredentialValidator.validateEmail("not-an-email"))
        XCTAssertThrowsError(try CredentialValidator.validateEmail("a@b"))
    }

    func testPasswordRules() {
        XCTAssertNoThrow(try CredentialValidator.validatePassword("scanner42"))
        XCTAssertThrowsError(try CredentialValidator.validatePassword("short1"))
        XCTAssertThrowsError(try CredentialValidator.validatePassword("onlyletters"))
        XCTAssertThrowsError(try CredentialValidator.validatePassword("12345678"))
    }
}

final class PasswordHasherTests: XCTestCase {
    func testHashAndVerify() throws {
        let hash = try PasswordHasher.hash("correct horse 1", iterations: 1_000)
        XCTAssertEqual(hash.salt.count, PasswordHasher.saltLength)
        XCTAssertEqual(hash.hash.count, PasswordHasher.keyLength)
        XCTAssertTrue(try PasswordHasher.verify("correct horse 1", against: hash))
        XCTAssertFalse(try PasswordHasher.verify("correct horse 2", against: hash))
    }

    func testSaltsAreUnique() throws {
        let a = try PasswordHasher.hash("same password 1", iterations: 1_000)
        let b = try PasswordHasher.hash("same password 1", iterations: 1_000)
        XCTAssertNotEqual(a.salt, b.salt)
        XCTAssertNotEqual(a.hash, b.hash)
    }

    func testDeterministicWithSameSalt() throws {
        let salt = Data(repeating: 7, count: 16)
        let a = try PasswordHasher.hash("password1", iterations: 1_000, salt: salt)
        let b = try PasswordHasher.hash("password1", iterations: 1_000, salt: salt)
        XCTAssertEqual(a, b)
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(PasswordHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(PasswordHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(PasswordHasher.constantTimeEquals(Data([1, 2]), Data([1, 2, 3])))
    }
}

final class LocalAuthServiceTests: XCTestCase {
    private func makeService(store: SecureStore = InMemorySecureStore(), defaults: UserDefaults = TestFactory.defaults()) -> LocalAuthService {
        LocalAuthService(store: store, defaults: defaults, iterations: 1_000)
    }

    func testRegisterSignOutSignInRestore() async throws {
        let store = InMemorySecureStore()
        let defaults = TestFactory.defaults()
        let service = makeService(store: store, defaults: defaults)

        let initial = await service.restoreSession()
        XCTAssertEqual(initial, .signedOut)

        let profile = try await service.register(email: "Ada@Example.com", password: "lovelace1", displayName: "Ada")
        XCTAssertEqual(profile.email, "ada@example.com")
        let restored = await service.restoreSession()
        XCTAssertEqual(restored, .signedIn(profile))

        try await service.signOut()
        let afterSignOut = await service.restoreSession()
        XCTAssertEqual(afterSignOut, .signedOut)

        let signedIn = try await service.signIn(email: "ada@example.com", password: "lovelace1")
        XCTAssertEqual(signedIn, profile)

        // A new service instance (app relaunch) restores the same session.
        let relaunched = makeService(store: store, defaults: defaults)
        let relaunchState = await relaunched.restoreSession()
        XCTAssertEqual(relaunchState, .signedIn(profile))
    }

    func testPasswordIsNeverStoredInPlainText() async throws {
        let store = InMemorySecureStore()
        let service = makeService(store: store)
        _ = try await service.register(email: "a@b.com", password: "secret123", displayName: "A")
        let raw = try XCTUnwrap(try store.data(for: "account.a@b.com"))
        XCTAssertNil(String(data: raw, encoding: .utf8)?.range(of: "secret123"))
    }

    func testWrongPasswordAndDuplicateAccount() async throws {
        let service = makeService()
        _ = try await service.register(email: "a@b.com", password: "secret123", displayName: "A")
        do {
            _ = try await service.signIn(email: "a@b.com", password: "wrong1234")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidCredentials)
        }
        do {
            _ = try await service.register(email: "A@B.com", password: "secret123", displayName: "A")
            XCTFail("expected duplicate")
        } catch {
            XCTAssertEqual(error as? AuthError, .accountExists)
        }
    }

    func testLockoutAfterRepeatedFailures() async throws {
        let service = makeService()
        _ = try await service.register(email: "a@b.com", password: "secret123", displayName: "A")
        for _ in 0..<5 {
            _ = try? await service.signIn(email: "a@b.com", password: "nope12345")
        }
        do {
            _ = try await service.signIn(email: "a@b.com", password: "secret123")
            XCTFail("expected lockout")
        } catch {
            guard case .tooManyAttempts = error as? AuthError else { return XCTFail("unexpected \(error)") }
        }
    }

    func testGuestModeAndProfileUpdate() async throws {
        let service = makeService()
        await service.continueAsGuest()
        let guestState = await service.restoreSession()
        XCTAssertEqual(guestState, .guest)

        _ = try await service.register(email: "a@b.com", password: "secret123", displayName: "A")
        let updated = try await service.updateProfile(displayName: "  Grace ")
        XCTAssertEqual(updated.displayName, "Grace")

        try await service.deleteAccount()
        let afterDelete = await service.restoreSession()
        XCTAssertEqual(afterDelete, .signedOut)
        do {
            _ = try await service.signIn(email: "a@b.com", password: "secret123")
            XCTFail("account should be gone")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidCredentials)
        }
    }

    func testBackendConfigurationRequiresHTTPS() {
        XCTAssertNil(BackendConfiguration.fromBundle(Bundle(for: LocalAuthServiceTests.self)))
    }
}

@MainActor
final class AuthViewModelTests: XCTestCase {
    func testSuccessfulSignInClearsPassword() async {
        let auth = MockAuthService()
        await auth.setSignInResult(.success(MockAuthService.user))
        let viewModel = AuthViewModel(authService: auth)
        viewModel.email = "a@b.com"
        viewModel.password = "secret123"
        XCTAssertTrue(viewModel.canSignIn)

        let state = await viewModel.signIn()
        XCTAssertEqual(state, .signedIn(MockAuthService.user))
        XCTAssertEqual(viewModel.password, "")
        XCTAssertNil(viewModel.error)
    }

    func testFailedSignInSurfacesError() async {
        let viewModel = AuthViewModel(authService: MockAuthService())
        viewModel.email = "a@b.com"
        viewModel.password = "bad"
        let state = await viewModel.signIn()
        XCTAssertNil(state)
        XCTAssertEqual(viewModel.error, .authenticationFailed(AuthError.invalidCredentials.localizedDescription))
        XCTAssertFalse(viewModel.isWorking)
    }

    func testRegisterRequiresMatchingPasswords() async {
        let viewModel = AuthViewModel(authService: MockAuthService())
        viewModel.password = "secret123"
        viewModel.confirmPassword = "secret124"
        let state = await viewModel.register()
        XCTAssertNil(state)
        XCTAssertNotNil(viewModel.error)
    }

    func testPasswordHint() {
        let viewModel = AuthViewModel(authService: MockAuthService())
        viewModel.password = "abc"
        XCTAssertNotNil(viewModel.passwordHint)
        viewModel.password = "abcdefg1"
        XCTAssertNil(viewModel.passwordHint)
    }

    func testGuest() async {
        let auth = MockAuthService()
        let viewModel = AuthViewModel(authService: auth)
        let state = await viewModel.continueAsGuest()
        XCTAssertEqual(state, .guest)
        let count = await auth.guestCount
        XCTAssertEqual(count, 1)
    }
}

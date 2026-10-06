import CommonCrypto
import Foundation
import Security

struct PasswordHash: Codable, Equatable, Sendable {
    var algorithm: String
    var iterations: UInt32
    var salt: Data
    var hash: Data
}

/// PBKDF2-HMAC-SHA256 password hashing (CommonCrypto). Passwords are never
/// stored — only a random per-account salt and the derived key.
enum PasswordHasher {
    static let algorithm = "PBKDF2-HMAC-SHA256"
    /// OWASP 2023 recommendation for PBKDF2-HMAC-SHA256.
    static let defaultIterations: UInt32 = 600_000
    static let saltLength = 16
    static let keyLength = 32

    static func hash(_ password: String, iterations: UInt32 = defaultIterations, salt: Data? = nil) throws -> PasswordHash {
        let salt = try salt ?? randomBytes(count: saltLength)
        let derived = try deriveKey(password: password, salt: salt, iterations: iterations)
        return PasswordHash(algorithm: algorithm, iterations: iterations, salt: salt, hash: derived)
    }

    static func verify(_ password: String, against stored: PasswordHash) throws -> Bool {
        guard stored.algorithm == algorithm else { return false }
        let derived = try deriveKey(password: password, salt: stored.salt, iterations: stored.iterations)
        return constantTimeEquals(derived, stored.hash)
    }

    static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw AuthError.storage("Secure random generation failed.") }
        return Data(bytes)
    }

    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> Data {
        let passwordBytes = Array(password.utf8)
        guard !passwordBytes.isEmpty else { throw AuthError.invalidCredentials }
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status: Int32 = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                passwordBuffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: passwordBytes.count) { passwordPointer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer,
                        passwordBytes.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        &derived,
                        keyLength
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else { throw AuthError.storage("Key derivation failed (\(status)).") }
        return Data(derived)
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

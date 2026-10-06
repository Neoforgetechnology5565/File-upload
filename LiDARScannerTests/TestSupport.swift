import Foundation
import ScanCore
import XCTest
@testable import LiDARScanner

/// Factories shared by app-level tests. None of these require LiDAR hardware:
/// geometry is synthetic and only exercises the non-capture code paths.
enum TestFactory {
    static func temporaryStorage() throws -> LocalFileStorageService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tests-\(UUID().uuidString)", isDirectory: true)
        return try LocalFileStorageService(rootURL: root)
    }

    static func scan(name: String = "Test Scan", type: ScanType = .object, created: Date = Date()) -> Scan {
        Scan(name: name, createdAt: created, type: type, status: .completed, device: .unknown)
    }

    static func objectGeometry() -> ScanGeometry {
        var mesh = RoomMeshBuilder.box(size: Vector3(0.4, 0.3, 0.2))
        mesh.colors = Array(repeating: SIMD3(200, 100, 50), count: mesh.vertexCount)
        let cloud = PointCloud(
            positions: (0..<50).map { Vector3(Float($0) * 0.01, 0, 0) },
            colors: Array(repeating: SIMD3(10, 20, 30), count: 50),
            normals: Array(repeating: Vector3(0, 1, 0), count: 50)
        )
        return ScanGeometry(pointCloud: cloud, mesh: mesh)
    }

    static func roomGeometry() -> ScanGeometry {
        let wall = RoomElement(kind: .wall, category: "Wall", dimensions: Vector3(4, 2.5, 0),
                               transform: Transform3D(translation: Vector3(0, 1.25, -2)), confidence: "high")
        let table = RoomElement(kind: .object, category: "Table", dimensions: Vector3(1, 0.7, 0.6),
                                transform: Transform3D(translation: Vector3(0, 0.35, 0)), confidence: "high")
        return ScanGeometry(room: RoomModel(elements: [wall, table]))
    }

    /// Writes a processed scan into a staging directory exactly like the
    /// processing service does.
    static func processedScan(storage: StorageService, geometry: ScanGeometry = objectGeometry(), type: ScanType = .object) throws -> ProcessedScan {
        let staging = try storage.makeStagingDirectory()
        try ScanGeometryCodec.write(geometry, to: staging.appendingPathComponent(ScanFileManifest.geometryFileName))
        try Data([0xFF, 0xD8, 0xFF]).write(to: staging.appendingPathComponent(ScanFileManifest.thumbnailFileName))
        var scan = Self.scan(type: type)
        scan.files = ScanFileManifest(geometryFile: ScanFileManifest.geometryFileName, thumbnailFile: ScanFileManifest.thumbnailFileName)
        scan.statistics = ScanStatistics.make(from: geometry, captureDuration: 10)
        return ProcessedScan(scan: scan, geometry: geometry, stagingDirectory: staging)
    }

    static func defaults() -> UserDefaults {
        let name = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    static func container(
        capabilities: DeviceCapabilities = .fullySupported,
        repository: ScanRepository = InMemoryScanRepository(),
        authService: AuthService? = nil
    ) throws -> AppContainer {
        let defaults = defaults()
        return AppContainer(
            capabilityProvider: FixedCapabilityProvider(value: capabilities),
            authService: authService ?? LocalAuthService(store: InMemorySecureStore(), defaults: defaults, iterations: 1_000),
            repository: repository,
            storage: try temporaryStorage(),
            exportService: DefaultExportService(),
            cloudSync: DisabledCloudSyncService(),
            thumbnailRenderer: NoThumbnailRenderer(),
            defaults: defaults
        )
    }
}

struct NoThumbnailRenderer: ThumbnailRendering {
    @MainActor func renderThumbnail(for geometry: ScanGeometry, size: CGSize) -> Data? { nil }
}

/// Scriptable AuthService for view-model tests.
actor MockAuthService: AuthService {
    nonisolated let providerName = "Mock"
    var restoreResult: AuthState = .signedOut
    var signInResult: Result<UserProfile, AuthError> = .failure(.invalidCredentials)
    private(set) var signOutCount = 0
    private(set) var guestCount = 0

    static let user = UserProfile(id: "u1", email: "a@b.com", displayName: "Ada", createdAt: Date(timeIntervalSince1970: 0))

    func setSignInResult(_ result: Result<UserProfile, AuthError>) { signInResult = result }
    func setRestoreResult(_ state: AuthState) { restoreResult = state }

    func restoreSession() async -> AuthState { restoreResult }
    func signIn(email: String, password: String) async throws -> UserProfile { try signInResult.get() }
    func register(email: String, password: String, displayName: String) async throws -> UserProfile { try signInResult.get() }
    func signOut() async throws { signOutCount += 1 }
    func continueAsGuest() async { guestCount += 1 }
    func updateProfile(displayName: String) async throws -> UserProfile {
        var user = try signInResult.get()
        user.displayName = displayName
        return user
    }
    func deleteAccount() async throws {}
}

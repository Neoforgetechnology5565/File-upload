import Foundation
import ScanCore

/// Composition root. Every service is created here and injected through
/// protocols, so implementations (local vs cloud, real vs test) can be
/// swapped without touching views or view models.
@MainActor
final class AppContainer {
    let capabilityProvider: DeviceCapabilityProviding
    let authService: AuthService
    let repository: ScanRepository
    let storage: StorageService
    let library: ScanLibraryService
    let processingService: ScanProcessingService
    let exportService: ExportService
    let cloudSync: CloudSyncService
    let settings: AppSettings
    let defaults: UserDefaults
    let measurementEngine = MeasurementEngine()
    let isUITesting: Bool

    init(
        capabilityProvider: DeviceCapabilityProviding,
        authService: AuthService,
        repository: ScanRepository,
        storage: StorageService,
        exportService: ExportService,
        cloudSync: CloudSyncService,
        thumbnailRenderer: ThumbnailRendering,
        defaults: UserDefaults,
        isUITesting: Bool = false
    ) {
        self.capabilityProvider = capabilityProvider
        self.authService = authService
        self.repository = repository
        self.storage = storage
        self.exportService = exportService
        self.cloudSync = cloudSync
        self.defaults = defaults
        self.isUITesting = isUITesting
        self.settings = AppSettings(defaults: defaults)
        self.library = ScanLibraryService(repository: repository, storage: storage, cloudSync: cloudSync)
        self.processingService = DefaultScanProcessingService(
            storage: storage,
            thumbnailRenderer: thumbnailRenderer,
            capabilityProvider: capabilityProvider
        )
    }

    /// Production configuration: SwiftData + Application Support files,
    /// Keychain-backed auth (REST backend when `LSBackendBaseURL` is set).
    static func live() throws -> AppContainer {
        let storage = try LocalFileStorageService()
        storage.purgeStaleStagingDirectories()
        let modelContainer = try SwiftDataScanRepository.makeContainer()
        let secureStore = KeychainSecureStore()
        let authService: AuthService
        if let backend = BackendConfiguration.fromBundle() {
            authService = RESTAuthService(configuration: backend, store: secureStore)
        } else {
            authService = LocalAuthService(store: secureStore)
        }
        return AppContainer(
            capabilityProvider: SystemDeviceCapabilityProvider(),
            authService: authService,
            repository: SwiftDataScanRepository(container: modelContainer),
            storage: storage,
            exportService: DefaultExportService(),
            cloudSync: DisabledCloudSyncService(),
            thumbnailRenderer: SceneKitThumbnailRenderer(),
            defaults: .standard
        )
    }

    /// Isolated configuration for UI tests (launch argument `-ui-testing`):
    /// in-memory database and secrets, temporary files, fresh defaults.
    /// `UITEST_CAPABILITIES=full` simulates a LiDAR-capable device for
    /// navigation tests only; capture screens still require real hardware.
    static func uiTesting(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> AppContainer {
        let suiteName = "lidarscanner.uitests"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uitests-\(UUID().uuidString)")
        let capabilities: DeviceCapabilities = environment["UITEST_CAPABILITIES"] == "full" ? .fullySupported : .unsupported
        return AppContainer(
            capabilityProvider: FixedCapabilityProvider(value: capabilities),
            authService: LocalAuthService(store: InMemorySecureStore(), defaults: defaults, iterations: 1_000),
            repository: InMemoryScanRepository(),
            storage: try LocalFileStorageService(rootURL: root),
            exportService: DefaultExportService(),
            cloudSync: DisabledCloudSyncService(),
            thumbnailRenderer: SceneKitThumbnailRenderer(),
            defaults: defaults,
            isUITesting: true
        )
    }
}

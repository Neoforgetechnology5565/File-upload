import Foundation
import Observation
import ScanCore

/// Navigation destinations inside the main NavigationStack.
enum Route: Hashable {
    case newScan
    case modeSelection
    case instructions
    case processing
    case result
    case resultMeasure
    case history
    case details(UUID)
    case viewer(UUID)
    case measure(UUID)
    case settings
    case profile
}

/// State of the scan currently being created (New Scan → Save).
@Observable
@MainActor
final class ScanFlowModel {
    var draft = ScanDraft.make()
    var isCapturePresented = false
    var captureOutput: CaptureOutput?
    var processed: ProcessedScan?
    var measurements: [ScanMeasurement] = []

    func begin(type: ScanType = .room) {
        draft = .make(type: type)
        captureOutput = nil
        processed = nil
        measurements = []
        isCapturePresented = false
    }

    func reset() {
        begin(type: draft.type)
    }
}

/// App-level state machine and router:
/// Launch → Onboarding → Device Capability Check → Login/Continue Locally → Home.
@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable {
        case launching
        case onboarding
        case compatibility
        case authentication
        case main
    }

    private(set) var phase: Phase = .launching
    private(set) var authState: AuthState = .unknown
    private(set) var capabilities: DeviceCapabilities = .unsupported
    var path: [Route] = []
    let scanFlow = ScanFlowModel()
    let container: AppContainer

    @ObservationIgnored private var compatibilityAcknowledgedThisLaunch = false
    @ObservationIgnored private let minimumSplashDuration: TimeInterval

    static let onboardingKey = "app.onboardingCompleted"
    static let compatibilityKey = "app.compatibilitySeen"

    init(container: AppContainer, minimumSplashDuration: TimeInterval = 0.8) {
        self.container = container
        self.minimumSplashDuration = minimumSplashDuration
    }

    var settings: AppSettings { container.settings }

    // MARK: Launch & phase transitions

    func launch() async {
        let start = Date()
        capabilities = container.capabilityProvider.capabilities()
        authState = await container.authService.restoreSession()
        let remaining = minimumSplashDuration - Date().timeIntervalSince(start)
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        phase = nextPhase()
    }

    func nextPhase() -> Phase {
        let defaults = container.defaults
        if !defaults.bool(forKey: Self.onboardingKey) {
            return .onboarding
        }
        let needsCompatibilityScreen = !defaults.bool(forKey: Self.compatibilityKey) || !capabilities.canScanAnything
        if needsCompatibilityScreen && !compatibilityAcknowledgedThisLaunch {
            return .compatibility
        }
        if !authState.canUseApp {
            return .authentication
        }
        return .main
    }

    func completeOnboarding() {
        container.defaults.set(true, forKey: Self.onboardingKey)
        phase = nextPhase()
    }

    func acknowledgeCompatibility() {
        container.defaults.set(true, forKey: Self.compatibilityKey)
        compatibilityAcknowledgedThisLaunch = true
        phase = nextPhase()
    }

    func refreshCapabilities() {
        capabilities = container.capabilityProvider.capabilities()
    }

    func requestCameraAccess() async -> CameraAuthorization {
        let status = await container.capabilityProvider.requestCameraAccess()
        refreshCapabilities()
        return status
    }

    // MARK: Authentication

    func didAuthenticate(_ state: AuthState) {
        authState = state
        path = []
        phase = nextPhase()
    }

    func updateUser(_ user: UserProfile) {
        authState = .signedIn(user)
    }

    func signOut() async throws {
        try await container.authService.signOut()
        authState = .signedOut
        path = []
        scanFlow.reset()
        phase = .authentication
    }

    func accountDeleted() {
        authState = .signedOut
        path = []
        phase = .authentication
    }

    /// Guest users can create an account / sign in at any time.
    func presentAuthentication() {
        phase = .authentication
    }

    func resetOnboarding() {
        container.defaults.removeObject(forKey: Self.onboardingKey)
        container.defaults.removeObject(forKey: Self.compatibilityKey)
        compatibilityAcknowledgedThisLaunch = false
        path = []
        phase = nextPhase()
    }

    // MARK: Navigation

    func startNewScan() {
        scanFlow.begin()
        path.append(.newScan)
    }

    func open(_ route: Route) {
        path.append(route)
    }

    func popToRoot() {
        path = []
    }

    /// Replaces the top of the stack (e.g. Processing → Result).
    func replaceTop(with route: Route) {
        if !path.isEmpty { path.removeLast() }
        path.append(route)
    }

    func captureFinished(_ output: CaptureOutput) {
        scanFlow.captureOutput = output
        scanFlow.isCapturePresented = false
        path.append(.processing)
    }

    func didSaveScan(id: UUID) {
        scanFlow.reset()
        path = [.details(id)]
    }

    func discardCurrentScan() {
        if let processed = scanFlow.processed {
            container.library.discard(processed)
        }
        scanFlow.reset()
        path = []
    }
}

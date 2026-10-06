import ScanCore
import XCTest
@testable import LiDARScanner

@MainActor
final class AppModelTests: XCTestCase {
    func testFirstLaunchFlow() async throws {
        let container = try TestFactory.container(capabilities: .fullySupported)
        let model = AppModel(container: container, minimumSplashDuration: 0)
        XCTAssertEqual(model.phase, .launching)

        await model.launch()
        XCTAssertEqual(model.phase, .onboarding)

        model.completeOnboarding()
        XCTAssertEqual(model.phase, .compatibility)

        model.acknowledgeCompatibility()
        XCTAssertEqual(model.phase, .authentication)

        model.didAuthenticate(.guest)
        XCTAssertEqual(model.phase, .main)
    }

    func testReturningUserSkipsToMain() async throws {
        let container = try TestFactory.container(capabilities: .fullySupported)
        container.defaults.set(true, forKey: AppModel.onboardingKey)
        container.defaults.set(true, forKey: AppModel.compatibilityKey)
        await container.authService.continueAsGuest()

        let model = AppModel(container: container, minimumSplashDuration: 0)
        await model.launch()
        XCTAssertEqual(model.phase, .main)
        XCTAssertEqual(model.authState, .guest)
    }

    func testUnsupportedDeviceAlwaysShowsCompatibilityOncePerLaunch() async throws {
        let container = try TestFactory.container(capabilities: .unsupported)
        container.defaults.set(true, forKey: AppModel.onboardingKey)
        container.defaults.set(true, forKey: AppModel.compatibilityKey)
        let model = AppModel(container: container, minimumSplashDuration: 0)
        await model.launch()
        XCTAssertEqual(model.phase, .compatibility)
        model.acknowledgeCompatibility()
        XCTAssertEqual(model.phase, .authentication)
    }

    func testScanFlowNavigation() throws {
        let model = AppModel(container: try TestFactory.container(), minimumSplashDuration: 0)
        model.startNewScan()
        XCTAssertEqual(model.path, [.newScan])
        model.open(.modeSelection)
        model.open(.instructions)
        model.replaceTop(with: .processing)
        XCTAssertEqual(model.path, [.newScan, .modeSelection, .processing])
        let id = UUID()
        model.didSaveScan(id: id)
        XCTAssertEqual(model.path, [.details(id)])
        model.popToRoot()
        XCTAssertTrue(model.path.isEmpty)
    }

    func testSignOutReturnsToAuthentication() async throws {
        let auth = MockAuthService()
        let container = try TestFactory.container(authService: auth)
        let model = AppModel(container: container, minimumSplashDuration: 0)
        model.didAuthenticate(.signedIn(MockAuthService.user))
        model.open(.settings)
        try await model.signOut()
        XCTAssertEqual(model.phase, .authentication)
        XCTAssertEqual(model.authState, .signedOut)
        XCTAssertTrue(model.path.isEmpty)
        let count = await auth.signOutCount
        XCTAssertEqual(count, 1)
    }
}

@MainActor
final class MeasurementViewModelTests: XCTestCase {
    private func makeViewModel(persisted: @escaping ([ScanMeasurement]) -> Void = { _ in }) -> MeasurementViewModel {
        MeasurementViewModel(
            geometry: TestFactory.objectGeometry(),
            measurements: [],
            unit: .centimeters,
            engine: MeasurementEngine(),
            persist: persisted
        )
    }

    func testDistanceCompletesAfterTwoPoints() {
        var saved: [ScanMeasurement] = []
        let viewModel = makeViewModel { saved = $0 }
        viewModel.handleTap(ViewerTapResult(worldPoint: Vector3(0, 0, 0)))
        XCTAssertEqual(viewModel.pendingPoints.count, 1)
        XCTAssertTrue(viewModel.measurements.isEmpty)

        viewModel.handleTap(ViewerTapResult(worldPoint: Vector3(0.3, 0.4, 0)))
        XCTAssertTrue(viewModel.pendingPoints.isEmpty)
        XCTAssertEqual(viewModel.measurements.count, 1)
        XCTAssertEqual(viewModel.formatted(viewModel.measurements[0]), "50.0 cm")
        XCTAssertEqual(saved.count, 1)
    }

    func testMissedTapShowsMessage() {
        let viewModel = makeViewModel()
        viewModel.handleTap(ViewerTapResult(worldPoint: nil))
        XCTAssertNotNil(viewModel.message)
        XCTAssertTrue(viewModel.pendingPoints.isEmpty)
    }

    func testAreaRequiresExplicitCompletion() {
        let viewModel = makeViewModel()
        viewModel.activeTool = .area
        viewModel.handleTap(ViewerTapResult(worldPoint: Vector3(0, 0, 0)))
        viewModel.handleTap(ViewerTapResult(worldPoint: Vector3(1, 0, 0)))
        XCTAssertFalse(viewModel.canComplete)
        viewModel.handleTap(ViewerTapResult(worldPoint: Vector3(1, 0, 1)))
        XCTAssertTrue(viewModel.canComplete)
        XCTAssertEqual(viewModel.pendingPreview, "5000.0 cm²")
        viewModel.completePending()
        XCTAssertEqual(viewModel.measurements.first?.result, .area(squareMeters: 0.5))
    }

    func testUndoClearAndToolSwitch() {
        let viewModel = makeViewModel()
        viewModel.handleTap(ViewerTapResult(worldPoint: .zero))
        viewModel.undoLastPoint()
        XCTAssertTrue(viewModel.pendingPoints.isEmpty)
        viewModel.handleTap(ViewerTapResult(worldPoint: .zero))
        viewModel.activeTool = .height
        XCTAssertTrue(viewModel.pendingPoints.isEmpty, "switching tools discards pending points")
    }

    func testModelBoundsAndDelete() {
        var saved: [ScanMeasurement] = []
        let viewModel = makeViewModel { saved = $0 }
        viewModel.addModelBounds()
        XCTAssertEqual(viewModel.measurements.first?.kind, .boundingBox)
        let measurement = viewModel.measurements[0]
        viewModel.delete(measurement)
        XCTAssertTrue(viewModel.measurements.isEmpty)
        XCTAssertTrue(saved.isEmpty)
    }
}

@MainActor
final class LibraryViewModelTests: XCTestCase {
    private func makeLibrary(scans: [Scan]) throws -> ScanLibraryService {
        ScanLibraryService(repository: InMemoryScanRepository(scans: scans), storage: try TestFactory.temporaryStorage(), cloudSync: DisabledCloudSyncService())
    }

    func testHomeShowsRecentScans() async throws {
        let scans = (0..<8).map { TestFactory.scan(name: "Scan \($0)", created: Date(timeIntervalSince1970: TimeInterval($0))) }
        let viewModel = HomeViewModel(library: try makeLibrary(scans: scans))
        await viewModel.load()
        XCTAssertEqual(viewModel.totalCount, 8)
        XCTAssertEqual(viewModel.recentScans.count, HomeViewModel.recentLimit)
        XCTAssertEqual(viewModel.recentScans.first?.name, "Scan 7")
    }

    func testHistoryFilteringAndDelete() async throws {
        let room = TestFactory.scan(name: "Kitchen", type: .room)
        let object = TestFactory.scan(name: "Lamp", type: .object)
        let viewModel = ScanHistoryViewModel(library: try makeLibrary(scans: [room, object]))
        await viewModel.load()
        XCTAssertEqual(viewModel.scans.count, 2)

        viewModel.typeFilter = .room
        await viewModel.load()
        XCTAssertEqual(viewModel.scans.map(\.name), ["Kitchen"])

        viewModel.typeFilter = nil
        viewModel.searchText = "lam"
        await viewModel.load()
        XCTAssertEqual(viewModel.scans.map(\.name), ["Lamp"])

        await viewModel.delete(object)
        XCTAssertTrue(viewModel.scans.isEmpty)
    }

    func testDetailsLoadRenameDelete() async throws {
        let scan = TestFactory.scan(name: "Sofa")
        let library = try makeLibrary(scans: [scan])
        let viewModel = ScanDetailsViewModel(scanID: scan.id, library: library)
        await viewModel.load()
        XCTAssertEqual(viewModel.scan?.name, "Sofa")

        await viewModel.rename(to: "Corner Sofa")
        XCTAssertEqual(viewModel.scan?.name, "Corner Sofa")

        await viewModel.rename(to: " ")
        XCTAssertNotNil(viewModel.error)

        let deleted = await viewModel.delete()
        XCTAssertTrue(deleted)
    }

    func testDetailsMissingScan() async throws {
        let viewModel = ScanDetailsViewModel(scanID: UUID(), library: try makeLibrary(scans: []))
        await viewModel.load()
        XCTAssertNil(viewModel.scan)
        XCTAssertEqual(viewModel.error, .scanNotFound)
    }
}

final class CaptureMappingTests: XCTestCase {
    func testYCbCrConversion() {
        XCTAssertEqual(DepthPointSampler.ycbcrToRGB(y: 255, cb: 128, cr: 128, videoRange: false), SIMD3(255, 255, 255))
        XCTAssertEqual(DepthPointSampler.ycbcrToRGB(y: 0, cb: 128, cr: 128, videoRange: false), SIMD3(0, 0, 0))
        let red = DepthPointSampler.ycbcrToRGB(y: 76, cb: 85, cr: 255, videoRange: false)
        XCTAssertGreaterThan(red.x, 240)
        XCTAssertLessThan(red.y, 10)
        XCTAssertEqual(DepthPointSampler.ycbcrToRGB(y: 16, cb: 128, cr: 128, videoRange: true), SIMD3(0, 0, 0))
    }

    func testPresetsMapToRealParameters() {
        XCTAssertLessThan(ObjectScanPreset.object.voxelSize, ObjectScanPreset.space.voxelSize)
        XCTAssertLessThan(ObjectScanPreset.object.thresholds.maximumDepth, ObjectScanPreset.space.thresholds.maximumDepth)
        XCTAssertEqual(PointDensity.high.depthStride, 2)
    }

    func testAppErrorMapping() {
        XCTAssertEqual(AppError.from(CancellationError()), .cancelled)
        XCTAssertEqual(AppError.from(StorageError.insufficientSpace(required: 2, available: 1)), .insufficientStorage)
        XCTAssertEqual(AppError.from(ExportError.nothingToExport(.ply)), .exportFailed(ExportError.nothingToExport(.ply).localizedDescription))
        XCTAssertTrue(AppError.cameraPermissionDenied.opensSettings)
        XCTAssertNotNil(AppError.insufficientMemory.recoverySuggestion)
    }
}

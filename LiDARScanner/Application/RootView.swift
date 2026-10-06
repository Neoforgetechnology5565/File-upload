import SwiftUI

/// Switches between the top-level phases of the app.
struct RootView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                SplashView()
            case .onboarding:
                OnboardingView()
            case .compatibility:
                DeviceCompatibilityView()
            case .authentication:
                AuthenticationFlowView()
            case .main:
                MainNavigationView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.phase)
        .environment(model)
        .environment(model.settings)
        .task {
            if model.phase == .launching {
                await model.launch()
            }
        }
    }
}

/// The signed-in / guest experience: a NavigationStack rooted at Home, plus
/// the full-screen capture experience.
struct MainNavigationView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var flow = model.scanFlow
        NavigationStack(path: $model.path) {
            HomeView(viewModel: HomeViewModel(library: model.container.library))
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .fullScreenCover(isPresented: $flow.isCapturePresented) {
            CaptureContainerView()
                .environment(model)
                .environment(model.settings)
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        let container = model.container
        switch route {
        case .newScan:
            NewScanView()
        case .modeSelection:
            ScanModeSelectionView()
        case .instructions:
            ScanInstructionsView()
        case .processing:
            ProcessingView(viewModel: ProcessingViewModel(service: container.processingService))
        case .result:
            ScanResultView()
        case .resultMeasure:
            if let processed = model.scanFlow.processed {
                MeasurementView(viewModel: MeasurementViewModel(
                    geometry: processed.geometry,
                    measurements: model.scanFlow.measurements,
                    unit: model.settings.preferredUnit,
                    engine: container.measurementEngine,
                    persist: { [flow = model.scanFlow] in flow.measurements = $0 }
                ))
            } else {
                ContentUnavailableView("Nothing to Measure", systemImage: "ruler")
            }
        case .history:
            ScanHistoryView(viewModel: ScanHistoryViewModel(library: container.library))
        case .details(let id):
            ScanDetailsView(viewModel: ScanDetailsViewModel(scanID: id, library: container.library))
        case .viewer(let id):
            ScanViewerView(viewModel: ScanViewerViewModel(scanID: id, library: container.library))
        case .measure(let id):
            SavedScanMeasurementView(scanID: id)
        case .settings:
            SettingsView()
        case .profile:
            ProfileView(viewModel: ProfileViewModel(authService: container.authService))
        }
    }
}

/// Chooses the capture experience for the current draft.
struct CaptureContainerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.scanFlow.draft.type {
        case .room:
            RoomScanView(
                onFinish: { model.captureFinished($0) },
                onCancel: { model.scanFlow.isCapturePresented = false }
            )
        case .object:
            ObjectScanView(
                viewModel: ObjectScanViewModel(
                    preset: model.scanFlow.draft.preset,
                    density: model.settings.pointDensity,
                    capabilities: model.capabilities
                ),
                onFinish: { model.captureFinished($0) },
                onCancel: { model.scanFlow.isCapturePresented = false }
            )
        }
    }
}

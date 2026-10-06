import SwiftUI

@main
@MainActor
struct LiDARScannerApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?

    init() {
        do {
            let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
            let container = try (isUITesting ? AppContainer.uiTesting() : AppContainer.live())
            _model = State(initialValue: AppModel(container: container, minimumSplashDuration: isUITesting ? 0 : 0.8))
        } catch {
            Log.app.fault("Startup failed: \(error.localizedDescription, privacy: .public)")
            _startupError = State(initialValue: AppError.from(error).localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView(model: model)
            } else {
                StartupFailureView(message: startupError ?? "Unknown error")
            }
        }
    }
}

/// Shown only if local storage cannot be initialized (e.g. disk full).
struct StartupFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("LiDAR Scanner Couldn't Start", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
            Text("Free up storage space and reopen the app.")
        }
    }
}

import ARKit
import Observation
import RealityKit
import ScanCore
import SwiftUI
import UIKit

@Observable
@MainActor
final class ObjectScanViewModel {
    enum Phase: Equatable {
        case preparing
        case ready
        case scanning
        case paused
        case finishing
        case failed(AppError)
    }

    private(set) var phase: Phase = .preparing
    private(set) var status = ObjectScanLiveStatus()
    let preset: ObjectScanPreset
    let density: PointDensity
    let capabilities: DeviceCapabilities

    @ObservationIgnored private var session: ObjectScanSession?
    @ObservationIgnored private var memoryObserver: NSObjectProtocol?

    init(preset: ObjectScanPreset, density: PointDensity, capabilities: DeviceCapabilities) {
        self.preset = preset
        self.density = density
        self.capabilities = capabilities
    }

    func attach(arSession: ARSession) {
        guard session == nil else { return }
        guard capabilities.canScanObjects else {
            phase = .failed(.lidarUnavailable)
            return
        }
        let scanSession = ObjectScanSession(session: arSession, preset: preset, density: density, capabilities: capabilities)
        scanSession.onStatus = { [weak self] status in
            self?.status = status
        }
        scanSession.onError = { [weak self] error in
            self?.phase = .failed(error)
        }
        session = scanSession
        scanSession.startPreview()
        phase = .ready

        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.scanning.warning("Memory warning during object scan")
                self?.session?.handleMemoryPressure()
            }
        }
    }

    func startScanning() {
        guard phase == .ready else { return }
        session?.startCapture()
        phase = .scanning
    }

    func pause() {
        guard phase == .scanning else { return }
        session?.pause()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        session?.resume()
        phase = .scanning
    }

    func reset() {
        session?.reset()
        status = ObjectScanLiveStatus()
        phase = .ready
    }

    var canFinish: Bool {
        (phase == .scanning || phase == .paused) && (status.pointCount > 0 || status.meshAnchorCount > 0)
    }

    func finish() async -> CaptureOutput? {
        guard canFinish, let session else { return nil }
        phase = .finishing
        let result = await session.finish()
        guard !result.rawMesh.isEmpty || result.grid.voxelCount > 0 else {
            phase = .failed(.noGeometryCaptured)
            return nil
        }
        return .object(result)
    }

    func stop() {
        session?.stop()
        if let memoryObserver {
            NotificationCenter.default.removeObserver(memoryObserver)
        }
        memoryObserver = nil
    }
}

struct ObjectScanView: View {
    let onFinish: (CaptureOutput) -> Void
    let onCancel: () -> Void

    @Environment(AppSettings.self) private var settings
    @State private var viewModel: ObjectScanViewModel
    @State private var confirmCancel = false
    @State private var confirmReset = false

    init(viewModel: ObjectScanViewModel, onFinish: @escaping (CaptureOutput) -> Void, onCancel: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.onFinish = onFinish
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            ScanARViewContainer(viewModel: viewModel, showMeshOverlay: settings.showMeshOverlay)
                .ignoresSafeArea()
                .accessibilityLabel("LiDAR camera view")

            VStack(spacing: 12) {
                topBar
                Spacer()
                if viewModel.phase == .scanning || viewModel.phase == .paused {
                    statsPanel
                }
                controls
            }
            .padding()

            if viewModel.phase == .finishing {
                Color.black.opacity(0.4).ignoresSafeArea()
                ProgressView("Collecting scan data…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            viewModel.stop()
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard Scan", role: .destructive) { onCancel() }
        }
        .confirmationDialog("Reset scan?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { viewModel.reset() }
        } message: {
            Text("Everything captured so far will be discarded.")
        }
        .alert("Scanning Problem", isPresented: failedBinding) {
            Button("Close", role: .cancel) { onCancel() }
        } message: {
            if case .failed(let error) = viewModel.phase {
                Text([error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n"))
            }
        }
    }

    private var failedBinding: Binding<Bool> {
        Binding(
            get: { if case .failed = viewModel.phase { return true } else { return false } },
            set: { _ in }
        )
    }

    private var topBar: some View {
        HStack {
            Button {
                if viewModel.canFinish { confirmCancel = true } else { onCancel() }
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Cancel scan")
            Spacer()
            StatusPill(feedback: viewModel.status.feedback)
            Spacer()
            Button { confirmReset = true } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(!(viewModel.phase == .scanning || viewModel.phase == .paused))
            .accessibilityLabel("Reset scan")
        }
    }

    private var statsPanel: some View {
        let status = viewModel.status
        return HStack(spacing: 20) {
            stat("Points", Formatters.count(status.pointCount))
            stat("Surface", status.meshSurfaceArea > 0 ? settings.preferredUnit.format(squareMeters: Double(status.meshSurfaceArea)) : "—")
            stat("Time", Formatters.duration(status.captureDuration))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch viewModel.phase {
        case .preparing:
            ProgressView("Starting LiDAR…")
                .padding()
                .background(.ultraThinMaterial, in: Capsule())
        case .ready:
            PrimaryButton(title: "Start Scanning", systemImage: "record.circle") {
                Haptics.tap(enabled: settings.hapticsEnabled)
                viewModel.startScanning()
            }
            .accessibilityIdentifier("object.start")
        case .scanning, .paused:
            HStack(spacing: 12) {
                Button {
                    viewModel.phase == .paused ? viewModel.resume() : viewModel.pause()
                } label: {
                    Label(viewModel.phase == .paused ? "Resume" : "Pause",
                          systemImage: viewModel.phase == .paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.white)

                PrimaryButton(title: "Finish", systemImage: "checkmark") {
                    Task {
                        if let output = await viewModel.finish() {
                            Haptics.success(enabled: settings.hapticsEnabled)
                            onFinish(output)
                        }
                    }
                }
                .disabled(!viewModel.canFinish)
            }
        case .finishing, .failed:
            EmptyView()
        }
    }
}

/// RealityKit `ARView` used purely as the camera preview + live mesh
/// overlay. The `ARSession` itself is driven by `ObjectScanSession`.
struct ScanARViewContainer: UIViewRepresentable {
    let viewModel: ObjectScanViewModel
    let showMeshOverlay: Bool

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        // We render no virtual content; disable effects to save GPU and battery.
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain, .disableGroundingShadows]
        if showMeshOverlay {
            // Live wireframe of ARKit's reconstructed mesh = real coverage feedback.
            view.debugOptions.insert(.showSceneUnderstanding)
        }
        viewModel.attach(arSession: view.session)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        if showMeshOverlay {
            uiView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            uiView.debugOptions.remove(.showSceneUnderstanding)
        }
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}

import Observation
import RoomPlan
import ScanCore
import SwiftUI
import UIKit

/// Live counts reported by RoomPlan while scanning (real detections only).
struct RoomLiveCounts: Equatable {
    var walls = 0
    var doors = 0
    var windows = 0
    var openings = 0
    var objects = 0
}

@Observable
@MainActor
final class RoomScanViewModel: RoomCaptureEventHandling {
    enum Phase: Equatable {
        case ready
        case scanning
        case finishing
        case failed(AppError)
    }

    private(set) var phase: Phase = .ready
    private(set) var feedback: ScanFeedback = .ready
    private(set) var counts = RoomLiveCounts()
    private(set) var startDate: Date?

    @ObservationIgnored weak var controller: RoomCaptureControlling?
    @ObservationIgnored var onFinish: ((CaptureOutput) -> Void)?

    func start() {
        guard phase == .ready, let controller else { return }
        controller.startCapture()
        phase = .scanning
        feedback = .initializing
        startDate = Date()
    }

    func finish() {
        guard phase == .scanning else { return }
        phase = .finishing
        feedback = .processing
        controller?.stopCapture()
    }

    func cancel() {
        controller?.cancelCapture()
    }

    var canFinish: Bool { phase == .scanning && counts.walls > 0 }

    // MARK: RoomCaptureEventHandling

    func roomCaptureDidStart() {
        if phase == .ready { phase = .scanning }
    }

    func roomCaptureDidUpdate(_ room: CapturedRoom) {
        counts = RoomLiveCounts(
            walls: room.walls.count,
            doors: room.doors.count,
            windows: room.windows.count,
            openings: room.openings.count,
            objects: room.objects.count
        )
        if phase == .scanning, counts.walls > 0, feedback == .tracking {
            feedback = .areaCaptured
        }
    }

    func roomCaptureDidProvide(_ instruction: RoomCaptureSession.Instruction) {
        guard phase == .scanning else { return }
        let mapped = RoomScanProcessor.feedback(for: instruction)
        feedback = (mapped == .tracking && counts.walls > 0) ? .areaCaptured : mapped
    }

    func roomCaptureDidEnd(data: CapturedRoomData?, error: Error?) {
        if let error {
            Log.room.error("RoomPlan session ended with error: \(error.localizedDescription, privacy: .public)")
            phase = .failed(.trackingFailed(error.localizedDescription))
            return
        }
        guard let data else {
            phase = .failed(.noGeometryCaptured)
            return
        }
        let duration = startDate.map { Date().timeIntervalSince($0) } ?? 0
        onFinish?(.room(data, duration: duration))
    }
}

struct RoomScanView: View {
    let onFinish: (CaptureOutput) -> Void
    let onCancel: () -> Void

    @Environment(AppSettings.self) private var settings
    @State private var viewModel = RoomScanViewModel()
    @State private var confirmCancel = false

    var body: some View {
        ZStack {
            RoomCaptureRepresentable(viewModel: viewModel)
                .ignoresSafeArea()
                .accessibilityLabel("Room scanning camera view")

            VStack(spacing: 12) {
                topBar
                Spacer()
                if viewModel.phase != .ready {
                    countsBar
                }
                bottomControls
            }
            .padding()

            if viewModel.phase == .finishing {
                Color.black.opacity(0.4).ignoresSafeArea()
                ProgressView("Finishing capture…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            viewModel.onFinish = { output in
                Haptics.success(enabled: settings.hapticsEnabled)
                onFinish(output)
            }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog("Discard this scan?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard Scan", role: .destructive) {
                viewModel.cancel()
                onCancel()
            }
        }
        .alert("Room Scan Failed", isPresented: failedBinding) {
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
        HStack(alignment: .top) {
            Button {
                if viewModel.phase == .scanning { confirmCancel = true } else { viewModel.cancel(); onCancel() }
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Cancel scan")
            Spacer()
            StatusPill(feedback: viewModel.feedback)
            Spacer()
            if let start = viewModel.startDate, viewModel.phase == .scanning {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(Formatters.duration(context.date.timeIntervalSince(start)))
                        .font(.subheadline.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .accessibilityLabel("Scan duration")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
    }

    private var countsBar: some View {
        HStack(spacing: 16) {
            countLabel(viewModel.counts.walls, "Walls", "square.split.bottomrightquarter")
            countLabel(viewModel.counts.doors, "Doors", "door.left.hand.open")
            countLabel(viewModel.counts.windows, "Windows", "window.vertical.closed")
            countLabel(viewModel.counts.objects, "Objects", "sofa")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func countLabel(_ value: Int, _ title: String, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
            Text("\(value)").font(.headline.monospacedDigit())
            Text(title).font(.caption2)
        }
        .accessibilityLabel("\(value) \(title)")
    }

    @ViewBuilder
    private var bottomControls: some View {
        switch viewModel.phase {
        case .ready:
            PrimaryButton(title: "Start Room Scan", systemImage: "record.circle") {
                Haptics.tap(enabled: settings.hapticsEnabled)
                viewModel.start()
            }
            .accessibilityIdentifier("room.start")
        case .scanning:
            PrimaryButton(title: "Done", systemImage: "checkmark") {
                viewModel.finish()
            }
            .disabled(!viewModel.canFinish)
            .accessibilityHint(viewModel.canFinish ? "Finish capturing and process the room" : "Scan at least one wall first")
        case .finishing, .failed:
            EmptyView()
        }
    }
}

/// Hosts `RoomCaptureViewController` and wires it to the view model.
struct RoomCaptureRepresentable: UIViewControllerRepresentable {
    let viewModel: RoomScanViewModel

    func makeUIViewController(context: Context) -> RoomCaptureViewController {
        let controller = RoomCaptureViewController()
        controller.eventHandler = viewModel
        viewModel.controller = controller
        return controller
    }

    func updateUIViewController(_ uiViewController: RoomCaptureViewController, context: Context) {}
}

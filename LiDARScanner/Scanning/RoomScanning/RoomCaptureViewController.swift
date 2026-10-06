import RoomPlan
import UIKit

/// Receives RoomPlan capture events on the main actor.
@MainActor
protocol RoomCaptureEventHandling: AnyObject {
    func roomCaptureDidStart()
    func roomCaptureDidUpdate(_ room: CapturedRoom)
    func roomCaptureDidProvide(_ instruction: RoomCaptureSession.Instruction)
    func roomCaptureDidEnd(data: CapturedRoomData?, error: Error?)
}

/// Commands the room-scan view model can issue to the capture controller.
@MainActor
protocol RoomCaptureControlling: AnyObject {
    func startCapture()
    func stopCapture()
    func cancelCapture()
}

/// Hosts Apple's `RoomCaptureView`, which provides the camera feed, RoomPlan's
/// built-in coaching overlay and the live 3D structure preview.
///
/// We drive the `RoomCaptureSession` ourselves and return `false` from
/// `captureView(shouldPresent:error:)` so the final `RoomBuilder` processing
/// runs in our own Processing step (with progress UI and error handling)
/// instead of inside the capture view.
///
/// `RoomCaptureViewDelegate` requires `NSCoding`, which `UIViewController`
/// already provides — this is why the delegate is a view controller.
final class RoomCaptureViewController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate, RoomCaptureControlling {
    weak var eventHandler: RoomCaptureEventHandling?

    private var roomCaptureView: RoomCaptureView?
    private var isCancelling = false
    private var isRunning = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let captureView = RoomCaptureView(frame: view.bounds)
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.captureSession.delegate = self
        captureView.delegate = self
        view.addSubview(captureView)
        roomCaptureView = captureView
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isRunning {
            isCancelling = true
            roomCaptureView?.captureSession.stop()
            isRunning = false
        }
    }

    // MARK: RoomCaptureControlling

    func startCapture() {
        guard let roomCaptureView, !isRunning else { return }
        isCancelling = false
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        roomCaptureView.captureSession.run(configuration: configuration)
        isRunning = true
    }

    func stopCapture() {
        guard isRunning else { return }
        roomCaptureView?.captureSession.stop()
        isRunning = false
    }

    func cancelCapture() {
        isCancelling = true
        stopCapture()
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        false
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {}

    // MARK: RoomCaptureSessionDelegate

    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        Task { @MainActor in self.eventHandler?.roomCaptureDidStart() }
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor in self.eventHandler?.roomCaptureDidUpdate(room) }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        Task { @MainActor in self.eventHandler?.roomCaptureDidProvide(instruction) }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in
            guard !self.isCancelling else { return }
            self.eventHandler?.roomCaptureDidEnd(data: error == nil ? data : nil, error: error)
        }
    }
}

import ARKit
import Foundation
import ScanCore

/// User-facing error model. Every failure surfaced in the UI is converted to
/// an `AppError` so messages are consistent, actionable and never leak raw
/// framework errors.
enum AppError: Error, LocalizedError, Equatable, Identifiable {
    case unsupportedDevice
    case lidarUnavailable
    case roomPlanUnavailable
    case cameraPermissionDenied
    case trackingFailed(String)
    case sessionInterrupted
    case insufficientMemory
    case processingFailed(String)
    case noGeometryCaptured
    case exportFailed(String)
    case storageFailed(String)
    case insufficientStorage
    case authenticationFailed(String)
    case invalidInput(String)
    case scanNotFound
    case cancelled
    case unexpected(String)

    var id: String { title + (errorDescription ?? "") }

    var title: String {
        switch self {
        case .unsupportedDevice: return "Device Not Supported"
        case .lidarUnavailable: return "LiDAR Unavailable"
        case .roomPlanUnavailable: return "Room Scanning Unavailable"
        case .cameraPermissionDenied: return "Camera Access Needed"
        case .trackingFailed: return "Tracking Failed"
        case .sessionInterrupted: return "Scan Interrupted"
        case .insufficientMemory: return "Not Enough Memory"
        case .processingFailed, .noGeometryCaptured: return "Processing Failed"
        case .exportFailed: return "Export Failed"
        case .storageFailed: return "Storage Error"
        case .insufficientStorage: return "Storage Full"
        case .authenticationFailed: return "Sign-In Problem"
        case .invalidInput: return "Check Your Input"
        case .scanNotFound: return "Scan Not Found"
        case .cancelled: return "Cancelled"
        case .unexpected: return "Something Went Wrong"
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            return "This device does not support the AR features required for scanning."
        case .lidarUnavailable:
            return "This device does not have a LiDAR Scanner. Scanning requires an iPhone Pro or iPad Pro with LiDAR."
        case .roomPlanUnavailable:
            return "Room scanning (RoomPlan) is not supported on this device."
        case .cameraPermissionDenied:
            return "LiDAR Scanner needs camera access to capture depth and images."
        case .trackingFailed(let detail):
            return "AR tracking failed: \(detail)"
        case .sessionInterrupted:
            return "The scanning session was interrupted."
        case .insufficientMemory:
            return "The device is running low on memory."
        case .processingFailed(let detail):
            return "The scan could not be processed: \(detail)"
        case .noGeometryCaptured:
            return "No usable 3D data was captured."
        case .exportFailed(let detail):
            return detail
        case .storageFailed(let detail):
            return "The scan could not be saved or read: \(detail)"
        case .insufficientStorage:
            return "There is not enough free storage on this device."
        case .authenticationFailed(let detail):
            return detail
        case .invalidInput(let detail):
            return detail
        case .scanNotFound:
            return "This scan no longer exists."
        case .cancelled:
            return "The operation was cancelled."
        case .unexpected(let detail):
            return detail
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .cameraPermissionDenied:
            return "Open Settings and allow camera access for LiDAR Scanner."
        case .trackingFailed, .sessionInterrupted:
            return "Reset the scan and move slowly in a well lit area with visible detail."
        case .insufficientMemory:
            return "Finish the scan now, or close other apps and scan a smaller area."
        case .noGeometryCaptured:
            return "Scan again, moving slowly and keeping surfaces within the LiDAR range (about 0.3–5 m)."
        case .insufficientStorage:
            return "Free up space in Settings › General › iPhone Storage and try again."
        case .storageFailed:
            return "Restart the app. If the problem persists, free up storage space."
        case .exportFailed:
            return "Try a different format, or re-open the scan and try again."
        default:
            return nil
        }
    }

    /// Whether the error relates to system permissions that only Settings can fix.
    var opensSettings: Bool {
        self == .cameraPermissionDenied
    }

    // MARK: - Mapping

    static func from(_ error: Error) -> AppError {
        switch error {
        case let appError as AppError:
            return appError
        case is CancellationError:
            return .cancelled
        case let arError as ARError:
            return from(arError)
        case let exportError as ExportError:
            return .exportFailed(exportError.localizedDescription)
        case let storageError as StorageError:
            if case .insufficientSpace = storageError { return .insufficientStorage }
            return .storageFailed(storageError.localizedDescription)
        case let authError as AuthError:
            return .authenticationFailed(authError.localizedDescription)
        case let codecError as ScanGeometryCodecError:
            return .storageFailed(codecError.localizedDescription)
        case let geometryError as GeometryError:
            return .processingFailed(geometryError.localizedDescription)
        case let measurementError as MeasurementError:
            return .invalidInput(measurementError.localizedDescription)
        case let nameError as ScanNameValidator.ValidationError:
            return .invalidInput(nameError.localizedDescription)
        case let cocoa as CocoaError where cocoa.code == .fileWriteOutOfSpace:
            return .insufficientStorage
        case let cocoa as CocoaError:
            return .storageFailed(cocoa.localizedDescription)
        default:
            return .unexpected(error.localizedDescription)
        }
    }

    static func from(_ error: ARError) -> AppError {
        switch error.code {
        case .cameraUnauthorized:
            return .cameraPermissionDenied
        case .unsupportedConfiguration:
            return .lidarUnavailable
        case .sensorUnavailable, .sensorFailed:
            return .trackingFailed("A required sensor is unavailable. Restart the app and try again.")
        case .worldTrackingFailed:
            return .trackingFailed("World tracking was lost.")
        default:
            return .trackingFailed(error.localizedDescription)
        }
    }
}

import Foundation

/// Platform-neutral mirror of `ARCamera.TrackingState`, so feedback logic is
/// testable without ARKit.
public enum TrackingCondition: Equatable, Sendable {
    case notAvailable
    case normal
    case initializing
    case relocalizing
    case excessiveMotion
    case insufficientFeatures
    case limitedOther
}

/// One observation derived from an ARFrame (all values measured, none guessed).
public struct FrameObservation: Equatable, Sendable {
    public var tracking: TrackingCondition
    /// Camera translation speed (m/s) between consecutive observations.
    public var linearSpeed: Float?
    /// Camera rotation speed (rad/s) between consecutive observations.
    public var angularSpeed: Float?
    /// Median LiDAR depth of the central image region (meters).
    public var medianCenterDepth: Float?

    public init(tracking: TrackingCondition, linearSpeed: Float? = nil, angularSpeed: Float? = nil, medianCenterDepth: Float? = nil) {
        self.tracking = tracking
        self.linearSpeed = linearSpeed
        self.angularSpeed = angularSpeed
        self.medianCenterDepth = medianCenterDepth
    }
}

public enum FeedbackSeverity: Int, Comparable, Sendable {
    case info = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: FeedbackSeverity, rhs: FeedbackSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// User-facing scanning guidance.
public enum ScanFeedback: Equatable, Sendable {
    case ready
    case initializing
    case tracking
    case areaCaptured
    case moveSlowly
    case tooFast
    case lowTracking(String)
    case relocalizing
    case moveCloser
    case moveFarther
    case paused
    case interrupted
    case memoryLimitReached
    case processing
    case trackingUnavailable

    public var message: String {
        switch self {
        case .ready: return "Ready to scan"
        case .initializing: return "Initializing — move your device slowly"
        case .tracking: return "Tracking"
        case .areaCaptured: return "Area captured"
        case .moveSlowly: return "Move slowly"
        case .tooFast: return "Too fast — slow down"
        case .lowTracking(let reason): return "Low tracking quality — \(reason)"
        case .relocalizing: return "Relocalizing — return to a previously scanned area"
        case .moveCloser: return "Move closer"
        case .moveFarther: return "Too close — move back"
        case .paused: return "Paused"
        case .interrupted: return "Session interrupted"
        case .memoryLimitReached: return "Memory limit reached — finish the scan"
        case .processing: return "Processing scan"
        case .trackingUnavailable: return "Tracking unavailable"
        }
    }

    public var severity: FeedbackSeverity {
        switch self {
        case .ready, .tracking, .areaCaptured, .processing, .paused: return .info
        case .initializing, .moveSlowly, .moveCloser, .moveFarther, .relocalizing: return .warning
        case .tooFast, .lowTracking, .interrupted, .memoryLimitReached, .trackingUnavailable: return .critical
        }
    }

    public var systemImage: String {
        switch self {
        case .ready: return "viewfinder"
        case .initializing: return "hourglass"
        case .tracking: return "dot.radiowaves.left.and.right"
        case .areaCaptured: return "checkmark.circle"
        case .moveSlowly, .tooFast: return "tortoise"
        case .lowTracking, .trackingUnavailable: return "exclamationmark.triangle"
        case .relocalizing: return "location.magnifyingglass"
        case .moveCloser: return "arrow.down.forward.and.arrow.up.backward"
        case .moveFarther: return "arrow.up.backward.and.arrow.down.forward"
        case .paused: return "pause.circle"
        case .interrupted: return "pause.octagon"
        case .memoryLimitReached: return "memorychip"
        case .processing: return "gearshape.2"
        }
    }

    /// Whether depth samples should be accumulated in this state.
    public var allowsCapture: Bool {
        switch self {
        case .tracking, .areaCaptured, .moveSlowly, .moveCloser, .moveFarther: return true
        default: return false
        }
    }
}

/// Distance/speed thresholds. Defaults are conservative values for the
/// iPhone/iPad LiDAR sensor (reliable range ≈ 0.25–5 m).
public struct FeedbackThresholds: Equatable, Sendable {
    public var minimumDepth: Float
    public var maximumDepth: Float
    public var slowDownLinearSpeed: Float
    public var tooFastLinearSpeed: Float
    public var slowDownAngularSpeed: Float
    public var tooFastAngularSpeed: Float

    public init(minimumDepth: Float, maximumDepth: Float, slowDownLinearSpeed: Float = 0.35, tooFastLinearSpeed: Float = 0.7, slowDownAngularSpeed: Float = 0.8, tooFastAngularSpeed: Float = 1.6) {
        self.minimumDepth = minimumDepth
        self.maximumDepth = maximumDepth
        self.slowDownLinearSpeed = slowDownLinearSpeed
        self.tooFastLinearSpeed = tooFastLinearSpeed
        self.slowDownAngularSpeed = slowDownAngularSpeed
        self.tooFastAngularSpeed = tooFastAngularSpeed
    }

    /// Small objects: stay within ~1.5 m.
    public static let object = FeedbackThresholds(minimumDepth: 0.25, maximumDepth: 1.5)
    /// Spaces/large objects: use most of the LiDAR range.
    public static let space = FeedbackThresholds(minimumDepth: 0.3, maximumDepth: 4.5)
}

/// Pure mapping from measured frame observations to scanning guidance.
public struct ScanFeedbackAnalyzer: Sendable {
    public var thresholds: FeedbackThresholds

    public init(thresholds: FeedbackThresholds) {
        self.thresholds = thresholds
    }

    public func feedback(for observation: FrameObservation, hasCapturedData: Bool) -> ScanFeedback {
        switch observation.tracking {
        case .notAvailable: return .trackingUnavailable
        case .initializing: return .initializing
        case .relocalizing: return .relocalizing
        case .excessiveMotion: return .tooFast
        case .insufficientFeatures: return .lowTracking("point at a more detailed, well lit area")
        case .limitedOther: return .lowTracking("hold steady")
        case .normal: break
        }

        let linear = observation.linearSpeed ?? 0
        let angular = observation.angularSpeed ?? 0
        if linear > thresholds.tooFastLinearSpeed || angular > thresholds.tooFastAngularSpeed {
            return .tooFast
        }
        if let depth = observation.medianCenterDepth {
            if depth < thresholds.minimumDepth { return .moveFarther }
            if depth > thresholds.maximumDepth { return .moveCloser }
        }
        if linear > thresholds.slowDownLinearSpeed || angular > thresholds.slowDownAngularSpeed {
            return .moveSlowly
        }
        return hasCapturedData ? .areaCaptured : .tracking
    }

    /// Angle (radians) between two camera orientations given as forward vectors.
    public static func angleBetween(_ a: Vector3, _ b: Vector3) -> Float {
        let cosine = max(-1, min(1, a.normalized.dot(b.normalized)))
        return acos(cosine)
    }
}

import Foundation
import Observation
import ScanCore

/// User preferences persisted in `UserDefaults`.
@Observable
@MainActor
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let unit = "settings.unit"
        static let pointDensity = "settings.pointDensity"
        static let showMeshOverlay = "settings.showMeshOverlay"
        static let plyEncoding = "settings.plyEncoding"
        static let plyContent = "settings.plyContent"
        static let objVertexColors = "settings.objVertexColors"
        static let haptics = "settings.haptics"
    }

    var preferredUnit: LengthUnit {
        didSet { defaults.set(preferredUnit.rawValue, forKey: Key.unit) }
    }

    var pointDensity: PointDensity {
        didSet { defaults.set(pointDensity.rawValue, forKey: Key.pointDensity) }
    }

    /// Show ARKit's reconstructed mesh over the camera while scanning.
    var showMeshOverlay: Bool {
        didSet { defaults.set(showMeshOverlay, forKey: Key.showMeshOverlay) }
    }

    var plyEncoding: PLYWriter.Encoding {
        didSet { defaults.set(plyEncoding.rawValue, forKey: Key.plyEncoding) }
    }

    var plyContent: PLYContent {
        didSet { defaults.set(plyContent.rawValue, forKey: Key.plyContent) }
    }

    var objIncludeVertexColors: Bool {
        didSet { defaults.set(objIncludeVertexColors, forKey: Key.objVertexColors) }
    }

    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.haptics) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let metricDefault: LengthUnit = Locale.current.measurementSystem == .us ? .feet : .meters
        preferredUnit = defaults.string(forKey: Key.unit).flatMap(LengthUnit.init(rawValue:)) ?? metricDefault
        pointDensity = defaults.string(forKey: Key.pointDensity).flatMap(PointDensity.init(rawValue:)) ?? .standard
        showMeshOverlay = defaults.object(forKey: Key.showMeshOverlay) as? Bool ?? true
        plyEncoding = defaults.string(forKey: Key.plyEncoding).flatMap(PLYWriter.Encoding.init(rawValue:)) ?? .binaryLittleEndian
        plyContent = defaults.string(forKey: Key.plyContent).flatMap(PLYContent.init(rawValue:)) ?? .automatic
        objIncludeVertexColors = defaults.object(forKey: Key.objVertexColors) as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: Key.haptics) as? Bool ?? true
    }

    var exportOptions: ExportOptions {
        ExportOptions(plyEncoding: plyEncoding, plyContent: plyContent, objIncludeVertexColors: objIncludeVertexColors)
    }
}

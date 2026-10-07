import Foundation

/// Display units for lengths and areas. Internal values are always meters.
public enum LengthUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case meters
    case centimeters
    case millimeters
    case feet
    case inches

    public var id: String { rawValue }

    /// Exact conversion factors (1 ft = 0.3048 m, 1 in = 0.0254 m by definition).
    public var metersPerUnit: Double {
        switch self {
        case .meters: return 1
        case .centimeters: return 0.01
        case .millimeters: return 0.001
        case .feet: return 0.3048
        case .inches: return 0.0254
        }
    }

    public var symbol: String {
        switch self {
        case .meters: return "m"
        case .centimeters: return "cm"
        case .millimeters: return "mm"
        case .feet: return "ft"
        case .inches: return "in"
        }
    }

    public var displayName: String {
        switch self {
        case .meters: return "Meters"
        case .centimeters: return "Centimeters"
        case .millimeters: return "Millimeters"
        case .feet: return "Feet"
        case .inches: return "Inches"
        }
    }

    /// Fraction digits shown by default. LiDAR depth is accurate to roughly a
    /// centimeter at best, so we never display sub-millimeter digits.
    public var defaultFractionDigits: Int {
        switch self {
        case .meters: return 2
        case .centimeters: return 1
        case .millimeters: return 0
        case .feet: return 2
        case .inches: return 1
        }
    }

    public func convert(meters: Double) -> Double {
        meters / metersPerUnit
    }

    public func toMeters(_ value: Double) -> Double {
        value * metersPerUnit
    }

    public func convert(squareMeters: Double) -> Double {
        squareMeters / (metersPerUnit * metersPerUnit)
    }

    public func format(meters: Double, fractionDigits: Int? = nil) -> String {
        let digits = fractionDigits ?? defaultFractionDigits
        return "\(Self.formatNumber(convert(meters: meters), digits: digits)) \(symbol)"
    }

    public func format(squareMeters: Double, fractionDigits: Int? = nil) -> String {
        let digits = fractionDigits ?? defaultFractionDigits
        return "\(Self.formatNumber(convert(squareMeters: squareMeters), digits: digits)) \(symbol)²"
    }

    /// Fixed-point, locale-independent formatting ("1234.50"). Implemented
    /// with `String(format:)` because `NumberFormatter` fraction-digit limits
    /// are not honored on every platform (e.g. swift-corelibs-foundation).
    static func formatNumber(_ value: Double, digits: Int) -> String {
        let clamped = max(0, min(digits, 6))
        let text = String(format: "%.\(clamped)f", value)
        return text == "-0" || text.hasPrefix("-0.") && Double(text) == 0 ? String(text.dropFirst()) : text
    }
}

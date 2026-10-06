import ScanCore
import SwiftUI
import UIKit

enum Theme {
    static let cornerRadius: CGFloat = 16
    static let spacing: CGFloat = 16
    static let readableWidth: CGFloat = 720
}

extension View {
    /// Constrains content to a comfortable reading width on iPad.
    func readableWidth() -> some View {
        frame(maxWidth: Theme.readableWidth)
            .frame(maxWidth: .infinity)
    }

    func cardStyle() -> some View {
        padding(Theme.spacing)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

/// Full-width prominent action button.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isLoading = false
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isLoading)
    }
}

/// Real-time scanning guidance badge.
struct StatusPill: View {
    let feedback: ScanFeedback

    private var tint: Color {
        switch feedback.severity {
        case .info: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }

    var body: some View {
        Label(feedback.message, systemImage: feedback.systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.9), lineWidth: 2))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scan status: \(feedback.message)")
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }
}

/// Loads and downsamples a thumbnail off the main thread.
struct ScanThumbnailView: View {
    let url: URL?
    let type: ScanType
    var cornerRadius: CGFloat = 12

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: type.systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 480, height: 480))
            }.value
        }
    }
}

struct ScanRowView: View {
    let scan: Scan
    let thumbnailURL: URL?

    var body: some View {
        HStack(spacing: 14) {
            ScanThumbnailView(url: thumbnailURL, type: scan.type)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(scan.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(scan.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Label(scan.type.shortName, systemImage: scan.type.systemImage)
                    if !scan.measurements.isEmpty {
                        Label("\(scan.measurements.count)", systemImage: "ruler")
                    }
                    if scan.isExported {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(scan.name), \(scan.type.displayName), \(scan.createdAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

/// Presents an `AppError` as an alert with an optional "Open Settings" action.
struct AppErrorAlert: ViewModifier {
    @Binding var error: AppError?

    func body(content: Content) -> some View {
        content.alert(
            error?.title ?? "Error",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
            presenting: error
        ) { error in
            if error.opensSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: { error in
            Text([error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n"))
        }
    }
}

extension View {
    func appErrorAlert(_ error: Binding<AppError?>) -> some View {
        modifier(AppErrorAlert(error: error))
    }
}

enum Haptics {
    @MainActor static func success(enabled: Bool = true) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @MainActor static func warning(enabled: Bool = true) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    @MainActor static func tap(enabled: Bool = true) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

enum Formatters {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds) ?? "–"
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func size(_ size: Vector3, unit: LengthUnit) -> String {
        "\(unit.format(meters: Double(size.x))) × \(unit.format(meters: Double(size.z))) × \(unit.format(meters: Double(size.y)))"
    }
}

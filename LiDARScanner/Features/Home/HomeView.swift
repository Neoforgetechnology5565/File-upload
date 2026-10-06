import Combine
import Observation
import ScanCore
import SwiftUI

@Observable
@MainActor
final class HomeViewModel {
    private(set) var recentScans: [Scan] = []
    private(set) var totalCount = 0
    private(set) var isLoading = false
    var error: AppError?

    private let library: ScanLibraryService
    static let recentLimit = 6

    init(library: ScanLibraryService) {
        self.library = library
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let all = try await library.scans(matching: ScanQuery(sortOrder: .newestFirst))
            totalCount = all.count
            recentScans = Array(all.prefix(Self.recentLimit))
        } catch {
            self.error = AppError.from(error)
        }
    }

    func thumbnailURL(for scan: Scan) -> URL? {
        library.thumbnailURL(for: scan)
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel: HomeViewModel

    init(viewModel: HomeViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !model.capabilities.canScanAnything {
                    capabilityBanner
                }
                newScanCard
                recentSection
            }
            .padding()
            .readableWidth()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("LiDAR Scanner")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { model.open(.profile) } label: {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel("Profile")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.open(.settings) } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .scanLibraryDidChange)) { _ in
            Task { await viewModel.load() }
        }
        .appErrorAlert($viewModel.error)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.title2.bold())
            Text(viewModel.totalCount == 1 ? "1 scan saved on this device" : "\(viewModel.totalCount) scans saved on this device")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var greeting: String {
        if let user = model.authState.user { return "Hello, \(user.displayName)" }
        return "Hello"
    }

    private var capabilityBanner: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scanning unavailable").font(.headline)
                Text("This device has no LiDAR Scanner. You can view and export existing scans.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .cardStyle()
    }

    private var newScanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("New Scan", systemImage: "viewfinder")
                .font(.headline)
            Text("Capture a room with RoomPlan or an object or space with LiDAR.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            PrimaryButton(title: "Start New Scan", systemImage: "plus.viewfinder") {
                model.startNewScan()
            }
            .disabled(!model.capabilities.canScanAnything)
            .accessibilityIdentifier("home.newScan")
        }
        .cardStyle()
    }

    @ViewBuilder
    private var recentSection: some View {
        HStack {
            Text("Recent Scans").font(.title3.bold())
            Spacer()
            Button("View All") { model.open(.history) }
                .accessibilityIdentifier("home.viewAll")
        }
        if viewModel.recentScans.isEmpty && !viewModel.isLoading {
            ContentUnavailableView(
                "No Scans Yet",
                systemImage: "cube.transparent",
                description: Text("Your saved scans will appear here.")
            )
            .accessibilityIdentifier("home.empty")
        } else {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(viewModel.recentScans) { scan in
                    Button { model.open(.details(scan.id)) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ScanThumbnailView(url: viewModel.thumbnailURL(for: scan), type: scan.type)
                                .aspectRatio(1, contentMode: .fit)
                            Text(scan.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(scan.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(scan.name), \(scan.type.displayName)")
                }
            }
        }
    }
}

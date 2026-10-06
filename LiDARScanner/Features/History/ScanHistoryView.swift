import Combine
import Observation
import ScanCore
import SwiftUI

@Observable
@MainActor
final class ScanHistoryViewModel {
    private(set) var scans: [Scan] = []
    private(set) var isLoading = false
    var error: AppError?

    var searchText = "" {
        didSet { scheduleReload() }
    }

    var typeFilter: ScanType? {
        didSet { scheduleReload() }
    }

    var sortOrder: ScanSortOrder = .newestFirst {
        didSet { scheduleReload() }
    }

    @ObservationIgnored private let library: ScanLibraryService
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(library: ScanLibraryService) {
        self.library = library
    }

    var query: ScanQuery {
        ScanQuery(searchText: searchText, type: typeFilter, sortOrder: sortOrder)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            scans = try await library.scans(matching: query)
        } catch {
            self.error = AppError.from(error)
        }
    }

    /// Debounces search typing.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func delete(_ scan: Scan) async {
        do {
            try await library.delete(id: scan.id)
            scans.removeAll { $0.id == scan.id }
        } catch {
            self.error = AppError.from(error)
        }
    }

    func thumbnailURL(for scan: Scan) -> URL? {
        library.thumbnailURL(for: scan)
    }
}

struct ScanHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel: ScanHistoryViewModel
    @State private var pendingDelete: Scan?

    init(viewModel: ScanHistoryViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        List {
            Section {
                Picker("Type", selection: $viewModel.typeFilter) {
                    Text("All").tag(ScanType?.none)
                    ForEach(ScanType.allCases) { type in
                        Text(type.shortName).tag(ScanType?.some(type))
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            ForEach(viewModel.scans) { scan in
                Button { model.open(.details(scan.id)) } label: {
                    ScanRowView(scan: scan, thumbnailURL: viewModel.thumbnailURL(for: scan))
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = scan }
                }
                .contextMenu {
                    Button("View in 3D", systemImage: "cube") { model.open(.viewer(scan.id)) }
                    Button("Measure", systemImage: "ruler") { model.open(.measure(scan.id)) }
                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = scan }
                }
            }
        }
        .overlay {
            if viewModel.scans.isEmpty && !viewModel.isLoading {
                if viewModel.searchText.isEmpty && viewModel.typeFilter == nil {
                    ContentUnavailableView("No Scans", systemImage: "cube.transparent", description: Text("Scans you save will appear here."))
                        .accessibilityIdentifier("history.empty")
                } else {
                    ContentUnavailableView.search(text: viewModel.searchText)
                }
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search names and notes")
        .navigationTitle("Scan History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $viewModel.sortOrder) {
                        ForEach(ScanSortOrder.allCases) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort")
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .scanLibraryDidChange)) { _ in
            Task { await viewModel.load() }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "scan")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Scan", role: .destructive) {
                if let scan = pendingDelete {
                    Task { await viewModel.delete(scan) }
                }
                pendingDelete = nil
            }
        } message: {
            Text("The scan and all its files and exports will be permanently deleted.")
        }
        .appErrorAlert($viewModel.error)
    }
}

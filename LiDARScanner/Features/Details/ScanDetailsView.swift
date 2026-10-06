import Combine
import Observation
import ScanCore
import SwiftUI

@Observable
@MainActor
final class ScanDetailsViewModel {
    let scanID: UUID
    private(set) var scan: Scan?
    private(set) var diskUsage: Int64 = 0
    private(set) var isLoading = false
    private(set) var isDeleted = false
    var error: AppError?

    @ObservationIgnored let library: ScanLibraryService

    init(scanID: UUID, library: ScanLibraryService) {
        self.scanID = scanID
        self.library = library
    }

    func load() async {
        guard !isDeleted else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let scan = try await library.scan(id: scanID)
            self.scan = scan
            diskUsage = library.diskUsage(for: scan)
        } catch {
            self.error = AppError.from(error)
        }
    }

    var thumbnailURL: URL? {
        scan.flatMap { library.thumbnailURL(for: $0) }
    }

    func rename(to name: String) async {
        do {
            scan = try await library.rename(id: scanID, to: name)
        } catch {
            self.error = AppError.from(error)
        }
    }

    func updateNotes(_ notes: String) async {
        do {
            scan = try await library.updateNotes(id: scanID, notes: notes)
        } catch {
            self.error = AppError.from(error)
        }
    }

    func deleteMeasurement(_ measurement: ScanMeasurement) async {
        guard var measurements = scan?.measurements else { return }
        measurements.removeAll { $0.id == measurement.id }
        do {
            scan = try await library.updateMeasurements(id: scanID, measurements: measurements)
        } catch {
            self.error = AppError.from(error)
        }
    }

    func delete() async -> Bool {
        do {
            try await library.delete(id: scanID)
            isDeleted = true
            return true
        } catch {
            self.error = AppError.from(error)
            return false
        }
    }
}

struct ScanDetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var viewModel: ScanDetailsViewModel
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var showExport = false

    init(viewModel: ScanDetailsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if let scan = viewModel.scan {
                content(scan)
            } else if viewModel.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView("Scan Not Found", systemImage: "questionmark.square.dashed")
            }
        }
        .navigationTitle(viewModel.scan?.name ?? "Scan")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .scanLibraryDidChange)) { _ in
            Task { await viewModel.load() }
        }
        .alert("Rename Scan", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await viewModel.rename(to: renameText) } }
        }
        .confirmationDialog("Delete this scan?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Scan", role: .destructive) {
                Task {
                    if await viewModel.delete() { model.popToRoot() }
                }
            }
        } message: {
            Text("This permanently deletes the scan, its 3D data, measurements and exports.")
        }
        .sheet(isPresented: $showExport) {
            if let scan = viewModel.scan {
                ExportView(viewModel: ExportViewModel(
                    scan: scan,
                    library: model.container.library,
                    exportService: model.container.exportService,
                    options: settings.exportOptions
                ))
            }
        }
        .appErrorAlert($viewModel.error)
    }

    private func content(_ scan: Scan) -> some View {
        List {
            Section {
                ScanThumbnailView(url: viewModel.thumbnailURL, type: scan.type, cornerRadius: Theme.cornerRadius)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                actionButton("View in 3D", "cube", id: "details.view") { model.open(.viewer(scan.id)) }
                actionButton("Measure", "ruler", id: "details.measure") { model.open(.measure(scan.id)) }
                actionButton("Export", "square.and.arrow.up", id: "details.export") { showExport = true }
            }

            Section("Statistics") {
                ScanStatisticsGrid(scan: scan, unit: settings.preferredUnit)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if let objects = scan.statistics.room?.objectCategories, !objects.isEmpty {
                Section("Detected Objects") {
                    ForEach(objects.sorted { $0.key < $1.key }, id: \.key) { entry in
                        InfoRow(label: entry.key, value: "\(entry.value)")
                    }
                }
            }

            Section("Measurements") {
                if scan.measurements.isEmpty {
                    Text("No measurements").foregroundStyle(.secondary)
                }
                ForEach(scan.measurements) { measurement in
                    InfoRow(label: measurement.label, value: measurement.result.formatted(unit: settings.preferredUnit))
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                Task { await viewModel.deleteMeasurement(measurement) }
                            }
                        }
                }
            }

            Section("Information") {
                InfoRow(label: "Type", value: scan.type.displayName)
                InfoRow(label: "Created", value: scan.createdAt.formatted(date: .long, time: .shortened))
                InfoRow(label: "Modified", value: scan.updatedAt.formatted(date: .long, time: .shortened))
                InfoRow(label: "Status", value: scan.status.displayName)
                InfoRow(label: "Device", value: "\(scan.device.modelIdentifier) · \(scan.device.systemName) \(scan.device.systemVersion)")
                InfoRow(label: "Storage", value: Formatters.bytes(viewModel.diskUsage))
                InfoRow(label: "Sync", value: scan.syncState == .localOnly ? "On this device only" : scan.syncState.rawValue)
                if let preset = scan.metadata["capture.preset"] {
                    InfoRow(label: "Capture preset", value: preset.capitalized)
                }
                if !scan.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.subheadline)
                        Text(scan.notes).foregroundStyle(.secondary)
                    }
                }
            }

            if !scan.exports.isEmpty {
                Section("Export History") {
                    ForEach(scan.exports.sorted { $0.exportedAt > $1.exportedAt }) { record in
                        InfoRow(label: "\(record.format.displayName) · \(Formatters.bytes(record.byteCount))",
                                value: record.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            Section {
                Button("Rename", systemImage: "pencil") {
                    renameText = scan.name
                    showRename = true
                }
                Button("Delete Scan", systemImage: "trash", role: .destructive) {
                    confirmDelete = true
                }
                .accessibilityIdentifier("details.delete")
            }
        }
    }

    private func actionButton(_ title: String, _ icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .accessibilityIdentifier(id)
    }
}

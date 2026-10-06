import Observation
import ScanCore
import SwiftUI

@Observable
@MainActor
final class ExportViewModel {
    let scan: Scan
    var options: ExportOptions
    var selectedFormat: ExportFormat = .usdz
    private(set) var geometry: ScanGeometry?
    private(set) var isLoading = false
    private(set) var isExporting = false
    private(set) var artifact: ExportArtifact?
    var error: AppError?

    @ObservationIgnored private let library: ScanLibraryService
    @ObservationIgnored private let exportService: ExportService

    init(scan: Scan, library: ScanLibraryService, exportService: ExportService, options: ExportOptions) {
        self.scan = scan
        self.library = library
        self.exportService = exportService
        self.options = options
    }

    func load() async {
        guard geometry == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            geometry = try await library.loadGeometry(for: scan)
            if let first = ExportFormat.allCases.first(where: { availability(of: $0).isAvailable }) {
                selectedFormat = first
            }
        } catch {
            self.error = AppError.from(error)
        }
    }

    func availability(of format: ExportFormat) -> ExportAvailability {
        guard let geometry else { return .unavailable("Loading…") }
        return exportService.availability(of: format, for: scan, geometry: geometry)
    }

    func export() async {
        guard let geometry else { return }
        isExporting = true
        artifact = nil
        defer { isExporting = false }
        do {
            let directory = try library.exportsDirectory(for: scan)
            let roomUSDZ = scan.files.roomUSDZFile.map { library.fileURL($0, for: scan) }
            let result = try await exportService.export(
                scan: scan,
                geometry: geometry,
                format: selectedFormat,
                options: options,
                roomUSDZURL: roomUSDZ,
                to: directory
            )
            artifact = result
            _ = try? await library.recordExport(
                id: scan.id,
                record: ExportRecord(format: result.format, fileName: result.primaryURL.lastPathComponent, byteCount: result.byteCount)
            )
        } catch {
            self.error = AppError.from(error)
        }
    }
}

struct ExportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ExportViewModel

    init(viewModel: ExportViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    ForEach(ExportFormat.allCases) { format in
                        let availability = viewModel.availability(of: format)
                        Button {
                            viewModel.selectedFormat = format
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(format.displayName).font(.headline)
                                    Text(availability.detail).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if viewModel.selectedFormat == format {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!availability.isAvailable)
                        .accessibilityAddTraits(viewModel.selectedFormat == format ? .isSelected : [])
                        .accessibilityIdentifier("export.\(format.rawValue)")
                    }
                }

                switch viewModel.selectedFormat {
                case .ply:
                    Section {
                        Picker("Encoding", selection: $viewModel.options.plyEncoding) {
                            Text("Binary").tag(PLYWriter.Encoding.binaryLittleEndian)
                            Text("ASCII").tag(PLYWriter.Encoding.ascii)
                        }
                        Picker("Content", selection: $viewModel.options.plyContent) {
                            Text("Automatic").tag(PLYContent.automatic)
                            Text("Point cloud").tag(PLYContent.pointCloud)
                            Text("Mesh").tag(PLYContent.mesh)
                        }
                    } header: {
                        Text("PLY Options")
                    } footer: {
                        Text("Includes XYZ, plus RGB colors and normals when the scan has them. Binary files are smaller and faster to load.")
                    }
                case .obj:
                    Section {
                        Toggle("Vertex colors", isOn: $viewModel.options.objIncludeVertexColors)
                    } header: {
                        Text("OBJ Options")
                    } footer: {
                        Text("Exports .obj with normals and a .mtl material file. Vertex colors use the common `v x y z r g b` extension. Texture maps are not generated.")
                    }
                case .usdz:
                    Section {
                        Text(viewModel.scan.type == .room
                             ? "Uses Apple RoomPlan's parametric USDZ with walls, doors, windows and objects."
                             : "USD mesh with materials, suitable for AR Quick Look and Reality Composer.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    PrimaryButton(title: "Export \(viewModel.selectedFormat.displayName)", systemImage: "square.and.arrow.up", isLoading: viewModel.isExporting) {
                        Task { await viewModel.export() }
                    }
                    .disabled(viewModel.geometry == nil || !viewModel.availability(of: viewModel.selectedFormat).isAvailable)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("export.run")
                }

                if let artifact = viewModel.artifact {
                    Section("Ready") {
                        Label(artifact.primaryURL.lastPathComponent, systemImage: "doc")
                        if let note = artifact.note {
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                        InfoRow(label: "Size", value: Formatters.bytes(artifact.byteCount))
                        ShareLink(items: artifact.shareURLs) {
                            Label("Share or Save to Files", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .overlay {
                if viewModel.isLoading { ProgressView("Loading scan…") }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await viewModel.load() }
            .appErrorAlert($viewModel.error)
        }
    }
}

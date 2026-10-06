import Observation
import ScanCore
import SwiftUI

@Observable
@MainActor
final class ScanViewerViewModel {
    let scanID: UUID
    private(set) var scan: Scan?
    private(set) var isLoading = false
    private(set) var availableModes: [ViewerDisplayMode] = []
    private(set) var selectedElement: RoomElement?
    var error: AppError?

    var displayMode: ViewerDisplayMode = .mesh {
        didSet { controller.setDisplayMode(displayMode) }
    }

    var wireframe = false {
        didSet { controller.setWireframe(wireframe) }
    }

    var showMeasurements = true {
        didSet { refreshAnnotations() }
    }

    var selectionEnabled = false {
        didSet {
            if !selectionEnabled { select(nil) }
        }
    }

    @ObservationIgnored let controller = SceneViewerController()
    @ObservationIgnored private var geometry: ScanGeometry?
    @ObservationIgnored private let library: ScanLibraryService

    init(scanID: UUID, library: ScanLibraryService) {
        self.scanID = scanID
        self.library = library
    }

    var isRoom: Bool { geometry?.room != nil }

    func load() async {
        guard geometry == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let scan = try await library.scan(id: scanID)
            let geometry = try await library.loadGeometry(for: scan)
            self.scan = scan
            self.geometry = geometry
            controller.load(geometry)
            controller.onTap = { [weak self] result in self?.handleTap(result) }
            availableModes = controller.availableDisplayModes
            displayMode = controller.displayMode
            refreshAnnotations()
        } catch {
            self.error = AppError.from(error)
        }
    }

    func handleTap(_ result: ViewerTapResult) {
        guard selectionEnabled else { return }
        select(result.elementID)
    }

    private func select(_ id: UUID?) {
        selectedElement = id.flatMap { id in geometry?.room?.elements.first { $0.id == id } }
        controller.highlightElement(selectedElement?.id)
    }

    private func refreshAnnotations() {
        controller.showAnnotations(measurements: showMeasurements ? (scan?.measurements ?? []) : [], pending: [])
    }
}

struct ScanViewerView: View {
    @Environment(AppSettings.self) private var settings
    @State private var viewModel: ScanViewerViewModel

    init(viewModel: ScanViewerViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScanSceneView(controller: viewModel.controller)
                .ignoresSafeArea(edges: .bottom)
            if viewModel.isLoading {
                ProgressView("Loading 3D model…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }
            VStack(spacing: 10) {
                if let element = viewModel.selectedElement {
                    selectionCard(element)
                }
                controls
            }
            .padding()
        }
        .navigationTitle(viewModel.scan?.name ?? "3D Viewer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { viewModel.controller.fitModel() } label: {
                    Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .accessibilityLabel("Fit model")
                Button { viewModel.controller.resetCamera() } label: {
                    Image(systemName: "camera.metering.center.weighted")
                }
                .accessibilityLabel("Reset camera")
            }
        }
        .task { await viewModel.load() }
        .appErrorAlert($viewModel.error)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if viewModel.availableModes.count > 1 {
                Picker("Display", selection: $viewModel.displayMode) {
                    ForEach(viewModel.availableModes) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
            Spacer(minLength: 0)
            Toggle(isOn: $viewModel.wireframe) {
                Image(systemName: "squareshape.split.3x3")
            }
            .toggleStyle(.button)
            .accessibilityLabel("Wireframe")
            .disabled(viewModel.displayMode == .points)
            Toggle(isOn: $viewModel.showMeasurements) {
                Image(systemName: "ruler")
            }
            .toggleStyle(.button)
            .accessibilityLabel("Show measurements")
            if viewModel.isRoom {
                Toggle(isOn: $viewModel.selectionEnabled) {
                    Image(systemName: "hand.tap")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Select objects")
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private func selectionCard(_ element: RoomElement) -> some View {
        let unit = settings.preferredUnit
        let d = element.dimensions
        let size = element.isSurface
            ? "\(unit.format(meters: Double(d.x))) × \(unit.format(meters: Double(d.y)))"
            : "W \(unit.format(meters: Double(d.x))) · D \(unit.format(meters: Double(d.z))) · H \(unit.format(meters: Double(d.y)))"
        return VStack(alignment: .leading, spacing: 4) {
            Label(element.category, systemImage: element.kind == .object ? "sofa" : "square.split.bottomrightquarter")
                .font(.headline)
            Text(size).font(.subheadline.monospacedDigit())
            Text("RoomPlan confidence: \(element.confidence)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .accessibilityElement(children: .combine)
    }
}

import Observation
import ScanCore
import SwiftUI

/// Point-picking measurement workflow on top of the 3D viewer. All
/// coordinates come from hit tests against the actual scan geometry.
@Observable
@MainActor
final class MeasurementViewModel {
    let geometry: ScanGeometry
    private(set) var measurements: [ScanMeasurement]
    private(set) var pendingPoints: [Vector3] = []
    var unit: LengthUnit
    var message: String?
    var error: AppError?

    var activeTool: MeasurementKind = .distance {
        didSet {
            pendingPoints = []
            message = nil
            refresh()
        }
    }

    @ObservationIgnored let controller = SceneViewerController()
    @ObservationIgnored private let engine: MeasurementEngine
    @ObservationIgnored private let persist: @MainActor ([ScanMeasurement]) -> Void
    @ObservationIgnored private var didAppear = false

    init(
        geometry: ScanGeometry,
        measurements: [ScanMeasurement],
        unit: LengthUnit,
        engine: MeasurementEngine,
        persist: @escaping @MainActor ([ScanMeasurement]) -> Void
    ) {
        self.geometry = geometry
        self.measurements = measurements
        self.unit = unit
        self.engine = engine
        self.persist = persist
    }

    var tools: [MeasurementKind] {
        engine.availableKinds
    }

    func onAppear() {
        guard !didAppear else { return }
        didAppear = true
        controller.load(geometry)
        controller.onTap = { [weak self] result in self?.handleTap(result) }
        refresh()
    }

    func handleTap(_ result: ViewerTapResult) {
        guard let point = result.worldPoint else {
            message = "No scan surface there — tap directly on the model."
            return
        }
        message = nil
        pendingPoints.append(point)
        if let tool = engine.tool(for: activeTool), tool.isComplete(pointCount: pendingPoints.count) {
            commit()
        } else {
            refresh()
        }
    }

    var instruction: String {
        let n = pendingPoints.count
        switch activeTool {
        case .distance, .height, .horizontalDistance:
            return n == 0 ? "Tap the first point" : "Tap the second point"
        case .area:
            return n < 3 ? "Tap at least 3 corners (\(n) selected)" : "Tap more corners or tap Complete"
        case .boundingBox:
            return n < 2 ? "Tap points to enclose (\(n) selected), or use Model Bounds" : "Tap more points or tap Complete"
        }
    }

    var canComplete: Bool {
        guard let tool = engine.tool(for: activeTool) else { return false }
        return tool.maximumPoints == nil && pendingPoints.count >= tool.minimumPoints
    }

    /// Live value for multi-point tools before committing.
    var pendingPreview: String? {
        guard canComplete, let tool = engine.tool(for: activeTool),
              let result = try? tool.compute(pendingPoints) else { return nil }
        return result.formatted(unit: unit)
    }

    func completePending() {
        commit()
    }

    func undoLastPoint() {
        guard !pendingPoints.isEmpty else { return }
        pendingPoints.removeLast()
        refresh()
    }

    func clearPending() {
        pendingPoints = []
        refresh()
    }

    func addModelBounds() {
        do {
            measurements.append(try engine.modelBounds(of: geometry))
            persist(measurements)
        } catch {
            self.error = AppError.from(error)
        }
        refresh()
    }

    func delete(_ measurement: ScanMeasurement) {
        measurements.removeAll { $0.id == measurement.id }
        persist(measurements)
        refresh()
    }

    func formatted(_ measurement: ScanMeasurement) -> String {
        measurement.result.formatted(unit: unit)
    }

    private func commit() {
        do {
            let index = measurements.filter { $0.kind == activeTool }.count + 1
            let measurement = try engine.measure(activeTool, points: pendingPoints, label: "\(activeTool.displayName) \(index)")
            measurements.append(measurement)
            persist(measurements)
        } catch {
            self.error = AppError.from(error)
        }
        pendingPoints = []
        refresh()
    }

    private func refresh() {
        controller.showAnnotations(measurements: measurements, pending: pendingPoints)
    }
}

struct MeasurementView: View {
    @State private var viewModel: MeasurementViewModel

    init(viewModel: MeasurementViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ScanSceneView(controller: viewModel.controller)
                instructionBanner
                    .padding()
            }
            panel
        }
        .navigationTitle("Measure")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Units", selection: $viewModel.unit) {
                        ForEach(LengthUnit.allCases) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    Button { viewModel.addModelBounds() } label: {
                        Label("Add Model Bounds", systemImage: "cube.transparent")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Measurement options")
            }
        }
        .onAppear { viewModel.onAppear() }
        .appErrorAlert($viewModel.error)
    }

    private var instructionBanner: some View {
        VStack(spacing: 6) {
            Text(viewModel.message ?? viewModel.instruction)
                .font(.subheadline.weight(.semibold))
            if let preview = viewModel.pendingPreview {
                Text(preview).font(.headline.monospacedDigit())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var panel: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.tools) { tool in
                        Button {
                            viewModel.activeTool = tool
                        } label: {
                            Label(tool.displayName, systemImage: tool.systemImage)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(viewModel.activeTool == tool ? Color.accentColor.opacity(0.2) : Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(viewModel.activeTool == tool ? .isSelected : [])
                    }
                }
                .padding(.horizontal)
            }

            if !viewModel.pendingPoints.isEmpty {
                HStack {
                    Button("Undo Point", systemImage: "arrow.uturn.backward") { viewModel.undoLastPoint() }
                    Spacer()
                    Button("Clear", role: .destructive) { viewModel.clearPending() }
                    if viewModel.canComplete {
                        Button("Complete") { viewModel.completePending() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal)
            }

            List {
                if viewModel.measurements.isEmpty {
                    Text("Measurements you take appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.measurements) { measurement in
                    HStack {
                        Label(measurement.label, systemImage: measurement.kind.systemImage)
                        Spacer()
                        Text(viewModel.formatted(measurement))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions {
                        Button("Delete", role: .destructive) { viewModel.delete(measurement) }
                    }
                }
            }
            .listStyle(.plain)
            .frame(height: 180)

            Text("Values come from LiDAR coordinates and inherit sensor error (typically ~1–2 cm at close range).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .padding(.top, 12)
        .background(.bar)
    }
}

/// Loads a saved scan, then hosts `MeasurementView` and persists changes.
struct SavedScanMeasurementView: View {
    let scanID: UUID
    @Environment(AppModel.self) private var model
    @State private var viewModel: MeasurementViewModel?
    @State private var error: AppError?

    var body: some View {
        Group {
            if let viewModel {
                MeasurementView(viewModel: viewModel)
            } else if error == nil {
                ProgressView("Loading scan…")
            } else {
                ContentUnavailableView("Couldn't Load Scan", systemImage: "exclamationmark.triangle")
            }
        }
        .task {
            guard viewModel == nil else { return }
            let library = model.container.library
            do {
                let scan = try await library.scan(id: scanID)
                let geometry = try await library.loadGeometry(for: scan)
                let id = scanID
                viewModel = MeasurementViewModel(
                    geometry: geometry,
                    measurements: scan.measurements,
                    unit: model.settings.preferredUnit,
                    engine: model.container.measurementEngine,
                    persist: { measurements in
                        Task {
                            do {
                                try await library.updateMeasurements(id: id, measurements: measurements)
                            } catch {
                                Log.persistence.error("Saving measurements failed: \(error.localizedDescription, privacy: .public)")
                            }
                        }
                    }
                )
            } catch {
                self.error = AppError.from(error)
            }
        }
        .appErrorAlert($error)
    }
}

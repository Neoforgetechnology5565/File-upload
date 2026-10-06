import ScanCore
import SwiftUI

/// 3D preview of a freshly processed scan, with measurements and saving.
struct ScanResultView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var viewer = SceneViewerController()
    @State private var name = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var error: AppError?
    @State private var confirmDiscard = false
    @State private var didLoad = false

    var body: some View {
        Group {
            if let processed = model.scanFlow.processed {
                content(processed)
            } else {
                ContentUnavailableView("No Scan", systemImage: "cube.transparent", description: Text("Start a new scan from Home."))
            }
        }
        .navigationTitle("Scan Result")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Discard", role: .destructive) { confirmDiscard = true }
            }
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Scan", role: .destructive) { model.discardCurrentScan() }
        } message: {
            Text("The captured data will be deleted.")
        }
        .appErrorAlert($error)
    }

    private func content(_ processed: ProcessedScan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScanSceneView(controller: viewer)
                    .frame(height: 380)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Button { viewer.resetCamera() } label: {
                            Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(10)
                        .accessibilityLabel("Fit model")
                    }

                ScanStatisticsGrid(scan: processed.scan, unit: settings.preferredUnit)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Measurements").font(.headline)
                        Spacer()
                        Button {
                            model.open(.resultMeasure)
                        } label: {
                            Label("Measure", systemImage: "ruler")
                        }
                        .accessibilityIdentifier("result.measure")
                    }
                    if model.scanFlow.measurements.isEmpty {
                        Text("No measurements yet. Tap Measure to pick points on the scan.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.scanFlow.measurements) { measurement in
                            InfoRow(label: measurement.label, value: measurement.result.formatted(unit: settings.preferredUnit))
                        }
                    }
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Save").font(.headline)
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("result.name")
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                    PrimaryButton(title: "Save Scan", systemImage: "square.and.arrow.down", isLoading: isSaving) {
                        Task { await save(processed) }
                    }
                    .accessibilityIdentifier("result.save")
                }
                .cardStyle()
            }
            .padding()
            .readableWidth()
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            name = processed.scan.name
            notes = processed.scan.notes
            viewer.load(processed.geometry)
            viewer.showAnnotations(measurements: model.scanFlow.measurements, pending: [])
        }
        .onChange(of: model.scanFlow.measurements) { _, measurements in
            viewer.showAnnotations(measurements: measurements, pending: [])
        }
    }

    private func save(_ processed: ProcessedScan) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let scan = try await model.container.library.save(
                processed,
                name: name,
                notes: notes,
                measurements: model.scanFlow.measurements,
                ownerID: model.authState.user?.id
            )
            Haptics.success(enabled: settings.hapticsEnabled)
            model.didSaveScan(id: scan.id)
        } catch {
            self.error = AppError.from(error)
        }
    }
}

/// Real, computed scan statistics (never estimated).
struct ScanStatisticsGrid: View {
    let scan: Scan
    let unit: LengthUnit

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            let stats = scan.statistics
            if let room = stats.room {
                MetricTile(title: "Walls", value: "\(room.wallCount)", systemImage: "square.split.bottomrightquarter")
                MetricTile(title: "Doors / Windows", value: "\(room.doorCount) / \(room.windowCount)", systemImage: "door.left.hand.open")
                MetricTile(title: "Objects", value: "\(room.objectCount)", systemImage: "sofa")
                MetricTile(title: "Wall height (max)", value: unit.format(meters: Double(room.maxWallHeight)), systemImage: "arrow.up.and.down")
                if let extent = room.footprintExtent {
                    MetricTile(title: "Footprint extent", value: "\(unit.format(meters: Double(extent.x))) × \(unit.format(meters: Double(extent.y)))", systemImage: "square.dashed")
                }
                MetricTile(title: "Total wall length", value: unit.format(meters: Double(room.totalWallLength)), systemImage: "ruler")
            } else {
                MetricTile(title: "Points", value: Formatters.count(stats.pointCount), systemImage: "circle.grid.3x3")
                MetricTile(title: "Triangles", value: Formatters.count(stats.triangleCount), systemImage: "triangle")
                if let area = stats.surfaceArea {
                    MetricTile(title: "Surface area", value: unit.format(squareMeters: Double(area)), systemImage: "square.on.square")
                }
            }
            if let size = stats.boundingBoxSize {
                MetricTile(title: "Bounds (W×D×H)", value: Formatters.size(size, unit: unit), systemImage: "cube.transparent")
            }
            MetricTile(title: "Capture time", value: Formatters.duration(stats.captureDuration), systemImage: "clock")
        }
    }
}

import ScanCore
import SwiftUI
import UIKit

/// Step 1: name the scan.
struct NewScanView: View {
    @Environment(AppModel.self) private var model
    @State private var nameError: String?

    var body: some View {
        @Bindable var flow = model.scanFlow
        Form {
            Section {
                TextField("Scan name", text: $flow.draft.name)
                    .accessibilityIdentifier("newScan.name")
                TextField("Notes (optional)", text: $flow.draft.notes, axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("Details")
            } footer: {
                if let nameError {
                    Text(nameError).foregroundStyle(.red)
                }
            }
            Section {
                PrimaryButton(title: "Choose Scan Type", systemImage: "arrow.right") {
                    do {
                        flow.draft.name = try ScanNameValidator.validate(flow.draft.name)
                        nameError = nil
                        model.open(.modeSelection)
                    } catch {
                        nameError = error.localizedDescription
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("newScan.next")
            }
        }
        .navigationTitle("New Scan")
    }
}

/// Step 2: choose Room (RoomPlan) or Object/Spatial (ARKit LiDAR).
struct ScanModeSelectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                modeCard(
                    type: .room,
                    title: "A. Room Scan",
                    subtitle: "Apple RoomPlan",
                    detail: "Walls, doors, windows, openings and furniture as a clean parametric model with room dimensions.",
                    available: model.capabilities.canScanRooms
                )
                modeCard(
                    type: .object,
                    title: "B. Object / Spatial Scan",
                    subtitle: "LiDAR depth + scene reconstruction",
                    detail: "Colored point cloud and 3D mesh of objects, furniture or areas, captured directly from the LiDAR Scanner.",
                    available: model.capabilities.canScanObjects
                )
            }
            .padding()
            .readableWidth()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Scan Type")
    }

    private func modeCard(type: ScanType, title: String, subtitle: String, detail: String, available: Bool) -> some View {
        Button {
            model.scanFlow.draft.type = type
            if model.scanFlow.draft.name.hasPrefix(ScanType.room.shortName) || model.scanFlow.draft.name.hasPrefix(ScanType.object.shortName) {
                model.scanFlow.draft.name = ScanNameValidator.defaultName(for: type)
            }
            model.open(.instructions)
        } label: {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: type.systemImage)
                    .font(.system(size: 32))
                    .frame(width: 48)
                    .foregroundStyle(available ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    Text(detail).font(.callout).foregroundStyle(.primary)
                    if !available {
                        Label("Not supported on this device", systemImage: "xmark.octagon")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.leading)
            .cardStyle()
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityIdentifier("mode.\(type.rawValue)")
    }
}

/// Step 3: scanning guidance, preset selection and camera permission.
struct ScanInstructionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var error: AppError?
    @State private var isRequesting = false

    var body: some View {
        @Bindable var flow = model.scanFlow
        let type = flow.draft.type
        List {
            Section {
                ForEach(tips(for: type)) { tip in
                    Label(tip.text, systemImage: tip.systemImage)
                }
            } header: {
                Text(type == .room ? "How to scan a room" : "How to scan an object or space")
            }

            if type == .object {
                Section {
                    Picker("Capture preset", selection: $flow.draft.preset) {
                        ForEach(ObjectScanPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(flow.draft.preset.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Preset")
                }
            }

            Section {
                Text(type == .room
                     ? "RoomPlan estimates dimensions from LiDAR and camera data. Results are suitable for planning and visualization, not for professional surveying."
                     : "Measurements use real LiDAR coordinates; typical accuracy is around 1–2 cm at close range and degrades with distance. Not a substitute for professional metrology.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Accuracy")
            }
        }
        .navigationTitle("Before You Scan")
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "Start Scanning", systemImage: "viewfinder", isLoading: isRequesting) {
                Task { await start() }
            }
            .accessibilityIdentifier("instructions.start")
            .padding()
            .readableWidth()
            .background(.bar)
        }
        .appErrorAlert($error)
    }

    private func start() async {
        let type = model.scanFlow.draft.type
        guard model.capabilities.canScan(type) else {
            error = type == .room ? .roomPlanUnavailable : .lidarUnavailable
            return
        }
        isRequesting = true
        let status = await model.requestCameraAccess()
        isRequesting = false
        guard status == .authorized else {
            error = .cameraPermissionDenied
            return
        }
        model.scanFlow.isCapturePresented = true
    }

    private struct Tip: Identifiable {
        let systemImage: String
        let text: String
        var id: String { text }
    }

    private func tips(for type: ScanType) -> [Tip] {
        switch type {
        case .room:
            return [
                Tip(systemImage: "lightbulb", text: "Turn on the lights and open doors you want captured."),
                Tip(systemImage: "figure.walk", text: "Start near a wall and walk slowly around the room's perimeter."),
                Tip(systemImage: "arrow.up.and.down", text: "Tilt the device up and down to capture the full height of walls."),
                Tip(systemImage: "sofa", text: "Point at furniture briefly so RoomPlan can detect it."),
                Tip(systemImage: "checkmark.circle", text: "Tap Done when the outline is complete.")
            ]
        case .object:
            return [
                Tip(systemImage: "sun.max", text: "Use even lighting. Avoid mirrors, glass and very dark or shiny surfaces."),
                Tip(systemImage: "tortoise", text: "Move slowly and steadily; keep the object in the center of the screen."),
                Tip(systemImage: "arrow.triangle.2.circlepath", text: "Walk all the way around the object, then capture the top."),
                Tip(systemImage: "ruler", text: "Stay within the preset's range — the app tells you to move closer or back."),
                Tip(systemImage: "square.grid.3x3", text: "The overlay shows the surface reconstructed so far.")
            ]
        }
    }
}

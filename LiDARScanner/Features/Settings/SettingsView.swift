import ScanCore
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var storageUsage: Int64?
    @State private var confirmClearExports = false
    @State private var error: AppError?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Units") {
                Picker("Measurement units", selection: $settings.preferredUnit) {
                    ForEach(LengthUnit.allCases) { unit in
                        Text("\(unit.displayName) (\(unit.symbol))").tag(unit)
                    }
                }
            }

            Section {
                Picker("Point density", selection: $settings.pointDensity) {
                    ForEach(PointDensity.allCases) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                Toggle("Show live mesh overlay", isOn: $settings.showMeshOverlay)
                Toggle("Haptic feedback", isOn: $settings.hapticsEnabled)
            } header: {
                Text("Scanning")
            } footer: {
                Text("High density samples twice as many LiDAR depth pixels per frame. It produces denser point clouds and uses more memory.")
            }

            Section("Export Defaults") {
                Picker("PLY encoding", selection: $settings.plyEncoding) {
                    Text("Binary").tag(PLYWriter.Encoding.binaryLittleEndian)
                    Text("ASCII").tag(PLYWriter.Encoding.ascii)
                }
                Picker("PLY content", selection: $settings.plyContent) {
                    Text("Automatic").tag(PLYContent.automatic)
                    Text("Point cloud").tag(PLYContent.pointCloud)
                    Text("Mesh").tag(PLYContent.mesh)
                }
                Toggle("OBJ vertex colors", isOn: $settings.objIncludeVertexColors)
            }

            Section("Storage") {
                InfoRow(label: "Used by scans", value: storageUsage.map(Formatters.bytes) ?? "Calculating…")
                Button("Delete Exported Files", role: .destructive) { confirmClearExports = true }
            }

            Section("Account") {
                Button { model.open(.profile) } label: {
                    Label(model.authState.user?.displayName ?? "Using locally", systemImage: "person.crop.circle")
                }
            }

            Section("Privacy & Permissions") {
                Button("Camera Permission Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Text("Scans and camera data are processed and stored on this device. Nothing is uploaded unless cloud sync is configured and enabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                InfoRow(label: "Version", value: SystemInfo.appVersion)
                InfoRow(label: "Device", value: SystemInfo.modelIdentifier)
                InfoRow(label: "LiDAR", value: model.capabilities.hasLiDAR ? "Available" : "Not available")
                InfoRow(label: "RoomPlan", value: model.capabilities.supportsRoomPlan ? "Available" : "Not available")
                Button("Show Onboarding Again") { model.resetOnboarding() }
            }
        }
        .navigationTitle("Settings")
        .task { await refreshUsage() }
        .confirmationDialog("Delete all exported files?", isPresented: $confirmClearExports, titleVisibility: .visible) {
            Button("Delete Exports", role: .destructive) {
                do {
                    try model.container.storage.removeAllExports()
                } catch {
                    self.error = AppError.from(error)
                }
                Task { await refreshUsage() }
            }
        } message: {
            Text("Your scans are kept. Exports can be regenerated at any time.")
        }
        .appErrorAlert($error)
    }

    private func refreshUsage() async {
        let storage = model.container.storage
        storageUsage = await Task.detached(priority: .utility) { storage.totalUsage() }.value
    }
}

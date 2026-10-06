import SwiftUI
import UIKit

/// Shows the result of the real hardware capability checks.
struct DeviceCompatibilityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let caps = model.capabilities
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .center, spacing: 12) {
                        Image(systemName: caps.canScanAnything ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(caps.canScanAnything ? .green : .orange)
                        Text(headline(caps))
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(summary(caps))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
                }

                Section("Device Checks") {
                    CheckRow(title: "LiDAR Scanner", passed: caps.hasLiDAR)
                    CheckRow(title: "Scene depth (LiDAR depth maps)", passed: caps.supportsSceneDepth)
                    CheckRow(title: "3D mesh reconstruction", passed: caps.supportsMeshReconstruction)
                    CheckRow(title: "Room scanning (RoomPlan)", passed: caps.supportsRoomPlan)
                    CheckRow(title: "World tracking", passed: caps.supportsWorldTracking)
                }

                Section {
                    CheckRow(title: "Camera access", passed: caps.cameraAuthorization == .authorized, pendingText: caps.cameraAuthorization == .notDetermined ? "Requested before scanning" : nil)
                    if caps.isCameraDenied {
                        Button("Open Settings to Allow Camera") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Camera access is used only to capture scans on this device.")
                }

                if !caps.canScanAnything {
                    Section {
                        Text("You can still sign in and browse scans, but capturing requires an iPhone Pro (12 Pro or later) or iPad Pro (2020 or later) with a LiDAR Scanner.")
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Compatibility")
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Continue") { model.acknowledgeCompatibility() }
                    .accessibilityIdentifier("compatibility.continue")
                    .padding()
                    .readableWidth()
                    .background(.bar)
            }
            .onAppear { model.refreshCapabilities() }
        }
    }

    private func headline(_ caps: DeviceCapabilities) -> String {
        if caps.canScanObjects && caps.canScanRooms { return "Your device is ready" }
        if caps.canScanAnything { return "Partially supported" }
        return "LiDAR not available"
    }

    private func summary(_ caps: DeviceCapabilities) -> String {
        if caps.canScanObjects && caps.canScanRooms {
            return "Room scanning and object/spatial LiDAR scanning are both available."
        }
        if caps.canScanObjects { return "Object and spatial scanning are available. Room scanning is not supported on this device." }
        if caps.canScanRooms { return "Room scanning is available. Object scanning needs LiDAR scene reconstruction." }
        return "This device doesn't have a LiDAR Scanner, so new scans can't be captured."
    }
}

private struct CheckRow: View {
    let title: String
    let passed: Bool
    var pendingText: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let pendingText, !passed {
                Text(pendingText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(passed ? .green : .red)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(passed ? "available" : (pendingText ?? "not available"))")
    }
}

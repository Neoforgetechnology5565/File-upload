import SwiftUI

struct SplashView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 72, weight: .thin))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: pulse)
                Text("LiDAR Scanner")
                    .font(.largeTitle.bold())
                ProgressView()
                    .padding(.top, 8)
            }
        }
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("LiDAR Scanner is starting")
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0

    private struct Page: Identifiable {
        let id: Int
        let systemImage: String
        let title: String
        let message: String
    }

    private let pages: [Page] = [
        Page(id: 0, systemImage: "house.and.flag", title: "Scan Rooms",
             message: "Capture walls, doors, windows and furniture with Apple RoomPlan and get a clean, measurable 3D floor model."),
        Page(id: 1, systemImage: "cube.transparent", title: "Scan Objects & Spaces",
             message: "Use the LiDAR Scanner to capture depth, color point clouds and 3D meshes of objects and areas."),
        Page(id: 2, systemImage: "ruler", title: "Measure in 3D",
             message: "Pick points directly on your scan to measure distances, heights, widths and areas in your preferred units."),
        Page(id: 3, systemImage: "square.and.arrow.up.on.square", title: "Save & Export",
             message: "Scans are stored privately on your device. Export them as USDZ, OBJ or PLY for use in other apps.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages) { item in
                    VStack(spacing: 24) {
                        Spacer()
                        Image(systemName: item.systemImage)
                            .font(.system(size: 80, weight: .light))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(item.title)
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text(item.message)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                    .readableWidth()
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 12) {
                PrimaryButton(title: page == pages.count - 1 ? "Get Started" : "Continue") {
                    if page < pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        model.completeOnboarding()
                    }
                }
                .accessibilityIdentifier("onboarding.continue")
                if page < pages.count - 1 {
                    Button("Skip") { model.completeOnboarding() }
                        .accessibilityIdentifier("onboarding.skip")
                }
            }
            .padding(24)
            .readableWidth()
        }
    }
}

import Observation
import SwiftUI

@Observable
@MainActor
final class ProfileViewModel {
    var displayName = ""
    private(set) var isSaving = false
    var error: AppError?

    @ObservationIgnored private let authService: AuthService

    init(authService: AuthService) {
        self.authService = authService
    }

    var providerName: String { authService.providerName }

    func save() async -> UserProfile? {
        isSaving = true
        defer { isSaving = false }
        do {
            return try await authService.updateProfile(displayName: displayName)
        } catch {
            self.error = AppError.from(error)
            return nil
        }
    }

    func deleteAccount() async -> Bool {
        do {
            try await authService.deleteAccount()
            return true
        } catch {
            self.error = AppError.from(error)
            return false
        }
    }
}

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel: ProfileViewModel
    @State private var confirmSignOut = false
    @State private var confirmDelete = false

    init(viewModel: ProfileViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Form {
            switch model.authState {
            case .signedIn(let user):
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(user.displayName).font(.title3.bold())
                            Text(user.email).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Section {
                    TextField("Display name", text: $viewModel.displayName)
                    Button("Save Name") {
                        Task {
                            if let updated = await viewModel.save() { model.updateUser(updated) }
                        }
                    }
                    .disabled(viewModel.isSaving || viewModel.displayName == user.displayName)
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Member since \(user.createdAt.formatted(date: .long, time: .omitted)). \(viewModel.providerName).")
                }
                Section {
                    Button("Sign Out") { confirmSignOut = true }
                        .accessibilityIdentifier("profile.signOut")
                    Button("Delete Account", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Signing out keeps scans on this device. Deleting your account does not delete saved scans.")
                }
                .onAppear { if viewModel.displayName.isEmpty { viewModel.displayName = user.displayName } }

            default:
                Section {
                    Label("Using LiDAR Scanner locally", systemImage: "iphone")
                    Text("Your scans are stored only on this device. Create an account to associate scans with a profile and enable cloud sync when it is configured.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Sign In or Create Account") { model.presentAuthentication() }
                        .accessibilityIdentifier("profile.signIn")
                }
            }
        }
        .navigationTitle("Profile")
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task {
                    do {
                        try await model.signOut()
                    } catch {
                        viewModel.error = AppError.from(error)
                    }
                }
            }
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) {
                Task {
                    if await viewModel.deleteAccount() { model.accountDeleted() }
                }
            }
        } message: {
            Text("Your account credentials will be removed. This cannot be undone.")
        }
        .appErrorAlert($viewModel.error)
    }
}

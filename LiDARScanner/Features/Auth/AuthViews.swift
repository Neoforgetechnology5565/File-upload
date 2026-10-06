import SwiftUI

/// Login / Register / Continue Locally.
struct AuthenticationFlowView: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel: AuthViewModel?
    @State private var showRegister = false

    var body: some View {
        NavigationStack {
            if let viewModel {
                LoginView(viewModel: viewModel, showRegister: $showRegister)
                    .navigationDestination(isPresented: $showRegister) {
                        RegisterView(viewModel: viewModel)
                    }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = AuthViewModel(authService: model.container.authService)
            }
        }
    }
}

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @Bindable var viewModel: AuthViewModel
    @Binding var showRegister: Bool
    @FocusState private var focused: Field?

    private enum Field { case email, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Welcome")
                        .font(.largeTitle.bold())
                    Text("Sign in to keep your scans associated with your account, or continue locally.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                VStack(spacing: 12) {
                    TextField("Email", text: $viewModel.email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                        .accessibilityIdentifier("login.email")
                    SecureField("Password", text: $viewModel.password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                        .accessibilityIdentifier("login.password")
                }
                .textFieldStyle(.roundedBorder)

                PrimaryButton(title: "Sign In", systemImage: "arrow.right.circle", isLoading: viewModel.isWorking) {
                    Task { await signIn() }
                }
                .disabled(!viewModel.canSignIn)
                .accessibilityIdentifier("login.signIn")

                Button("Create Account") { showRegister = true }
                    .accessibilityIdentifier("login.createAccount")

                Divider()

                Button {
                    Task { model.didAuthenticate(await viewModel.continueAsGuest()) }
                } label: {
                    Label("Continue Locally", systemImage: "iphone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("login.continueLocally")

                Text(viewModel.providerName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .appErrorAlert($viewModel.error)
    }

    private func signIn() async {
        guard viewModel.canSignIn else { return }
        if let state = await viewModel.signIn() {
            model.didAuthenticate(state)
        }
    }
}

struct RegisterView: View {
    @Environment(AppModel.self) private var model
    @Bindable var viewModel: AuthViewModel

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $viewModel.displayName)
                    .textContentType(.name)
                    .accessibilityIdentifier("register.name")
                TextField("Email", text: $viewModel.email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("register.email")
            }
            Section {
                SecureField("Password", text: $viewModel.password)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("register.password")
                SecureField("Confirm Password", text: $viewModel.confirmPassword)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("register.confirm")
            } header: {
                Text("Password")
            } footer: {
                Text(viewModel.passwordHint ?? "At least 8 characters with a letter and a number.")
                    .foregroundStyle(viewModel.passwordHint == nil ? Color.secondary : Color.orange)
            }
            Section {
                PrimaryButton(title: "Create Account", isLoading: viewModel.isWorking) {
                    Task {
                        if let state = await viewModel.register() {
                            model.didAuthenticate(state)
                        }
                    }
                }
                .disabled(!viewModel.canRegister)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("register.submit")
            } footer: {
                Text("Passwords are never stored. \(viewModel.providerName).")
            }
        }
        .navigationTitle("Create Account")
        .appErrorAlert($viewModel.error)
    }
}

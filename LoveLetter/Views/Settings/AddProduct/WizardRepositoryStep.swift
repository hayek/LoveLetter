import SwiftUI

/// The Add Product wizard's first step: pick one of a connected account's repositories, or name
/// a new one to create. Rendered as sections of the wizard's Form.
struct WizardRepositoryStep: View {
    @Bindable var model: AddProductWizardModel
    let accountStore: GitHubAccountStore
    /// Mock-data mode: GitHub sign-in is off, so the repository can only be typed in.
    let isMockDataMode: Bool
    var onConnectAccount: () -> Void

    @State private var accountID: UUID?
    @State private var repos: [UUID: LoadState] = [:]
    @State private var search = ""
    @State private var showManual = false

    private enum LoadState {
        case loading, loaded([GitHubRepo]), failed(String), expired
    }

    /// Someone who can own a new repository: the account's user or one of its organizations.
    private struct Owner: Hashable {
        let login: String
        let isOrganization: Bool
    }

    private var accounts: [GitHubAccount] { accountStore.accounts }
    private var account: GitHubAccount? { accounts.first { $0.id == accountID } ?? accounts.first }

    var body: some View {
        Group {
            if accounts.isEmpty {
                signInSection
                manualSection
            } else {
                Section {
                    Picker("Repository", selection: $model.repositoryMode) {
                        Text("Existing").tag(AddProductWizardModel.RepositoryMode.existing)
                        Text("New").tag(AddProductWizardModel.RepositoryMode.new)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if accounts.count > 1 {
                        Picker("Account", selection: Binding(get: { account?.id }, set: { accountID = $0 })) {
                            ForEach(accounts, id: \.id) { Text("@\($0.login)").tag(Optional($0.id)) }
                        }
                    }
                }

                switch model.repositoryMode {
                case .existing:
                    existingSection
                    manualSection
                case .new:
                    newSection
                }

                Section {
                    Button("Connect Another GitHub Account…", action: onConnectAccount)
                        .disabled(isMockDataMode)
                }
            }
        }
        .onAppear {
            if accounts.isEmpty { showManual = true }
            loadIfNeeded()
        }
        .onChange(of: account?.id) {
            loadIfNeeded()
            if model.createsRepository { selectOwner(nil) }
        }
        .onChange(of: model.repositoryMode) { _, mode in
            if mode == .new { selectOwner(nil) }
        }
    }

    // MARK: - Sign in

    private var signInSection: some View {
        Section {
            Button {
                onConnectAccount()
            } label: {
                Label("Sign in with GitHub", systemImage: "person.badge.key.fill")
            }
            .disabled(isMockDataMode)
        } footer: {
            Text(isMockDataMode
                 ? "GitHub sign-in is off while using mock data. Enter the repository below."
                 : "Sign in to pick a repository or create a new one, or enter one below.")
        }
    }

    // MARK: - Existing

    @ViewBuilder
    private var existingSection: some View {
        Section {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search, prompt: Text("Search repositories"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
            }
            if let account {
                switch repos[account.id] ?? .loading {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading repositories…").foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    retryRow(message, action: "Retry") { load(account) }
                case .expired:
                    retryRow("The GitHub session expired.", action: "Reconnect", perform: onConnectAccount)
                case .loaded(let all):
                    let shown = all.filter { search.isEmpty || $0.fullName.localizedCaseInsensitiveContains(search) }
                    if shown.isEmpty {
                        Text(all.isEmpty ? "This account has no repositories." : "No matches.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shown) { repoRow($0, account: account) }
                }
            }
        } footer: {
            if model.isDuplicateRepository {
                Label("\(model.repoFullName) is already a product.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func repoRow(_ repo: GitHubRepo, account: GitHubAccount) -> some View {
        let key = repo.fullName.lowercased()
        let isAdded = model.existingRepoKeys.contains(key)
        let isSelected = model.repositoryMode == .existing && model.selectedRepoKey == key
        return Button {
            model.owner = repo.owner.login
            model.repo = repo.name
            model.token = accountStore.token(for: account) ?? ""
            model.repoIsPrivate = repo.isPrivate
        } label: {
            HStack(spacing: 10) {
                Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.name)
                    // Only repos the account doesn't own need their owner spelled out.
                    if repo.owner.login.caseInsensitiveCompare(account.login) != .orderedSame {
                        Text(repo.owner.login).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isAdded {
                    Text("Added").foregroundStyle(.tertiary)
                } else if isSelected {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                }
            }
            .foregroundStyle(isAdded ? .secondary : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func retryRow(_ message: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Text(message).foregroundStyle(.secondary)
            Spacer()
            Button(action, action: perform)
        }
    }

    @ViewBuilder
    private var manualSection: some View {
        Section {
            DisclosureGroup("Enter Manually", isExpanded: $showManual) {
                TextField("Owner", text: manual(\.owner), prompt: Text("owner"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("Repository", text: manual(\.repo), prompt: Text("repo-name"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Token", text: $model.token, prompt: Text("ghp_…"))
            }
        } footer: {
            if showManual {
                Text("The token needs read and write access to the repository's issues. It's stored in your Keychain.")
            }
        }
    }

    /// Manual edits clear the picked repo's privacy flag — it's unknown for a typed-in repo.
    private func manual(_ keyPath: ReferenceWritableKeyPath<AddProductWizardModel, String>) -> Binding<String> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0; model.repoIsPrivate = nil }
        )
    }

    // MARK: - New

    @ViewBuilder
    private var newSection: some View {
        let name = model.repo.trimmingCharacters(in: .whitespaces)
        Section {
            Picker("Owner", selection: Binding(get: { currentOwner }, set: { selectOwner($0) })) {
                ForEach(owners, id: \.self) { owner in
                    Text(owner.login).tag(Optional(owner))
                }
            }
            TextField("Name", text: $model.repo, prompt: Text("myapp-feedback"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Toggle("Private", isOn: Binding(get: { model.repoIsPrivate ?? true }, set: { model.repoIsPrivate = $0 }))
        } footer: {
            if let error = model.newRepoError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if !name.isEmpty && !ProductSetup.isValidRepositoryName(name) {
                Label("Use only letters, numbers, hyphens, underscores and periods.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text("It's created when you finish, with the labels the Love Letter SDK uses. Private is recommended: feedback can include people's email addresses.")
            }
        }
    }

    /// The account's user, then the organizations it has repositories in.
    private var owners: [Owner] {
        guard let account else { return [] }
        var orgs: [String] = []
        if case .loaded(let all) = repos[account.id] {
            orgs = Set(all.filter(\.owner.isOrganization).map(\.owner.login))
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        return [Owner(login: account.login, isOrganization: false)]
            + orgs.map { Owner(login: $0, isOrganization: true) }
    }

    private var currentOwner: Owner? {
        owners.first { $0.login == model.owner }
    }

    /// Points the new repository at `owner` (nil: the account's user) and that account's token.
    private func selectOwner(_ owner: Owner?) {
        guard let account, let owner = owner ?? owners.first else { return }
        model.owner = owner.login
        model.newRepoOwnerIsOrganization = owner.isOrganization
        model.token = accountStore.token(for: account) ?? ""
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        guard let account, repos[account.id] == nil else { return }
        load(account)
    }

    private func load(_ account: GitHubAccount) {
        repos[account.id] = .loading
        Task {
            guard let token = accountStore.token(for: account) else {
                repos[account.id] = .expired
                return
            }
            do {
                repos[account.id] = .loaded(try await GitHubAuthService().listRepos(token: token))
            } catch GitHubAuthService.AuthError.apiError(let code) where code == 401 || code == 403 {
                repos[account.id] = .expired
            } catch {
                repos[account.id] = .failed(error.localizedDescription)
            }
        }
    }
}

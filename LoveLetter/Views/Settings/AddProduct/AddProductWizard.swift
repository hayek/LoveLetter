import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Step-by-step "Add Product" flow: pick the feedback sources (any combination of the SDK, App
/// Store reviews and an email inbox), connect the GitHub repository every source files into, set
/// up each chosen source, then review, name and tint the product.
struct AddProductWizard: View {
    var store: ProductStore
    /// Called with the new product's id once it's saved, so the caller can select it.
    var onCreated: (UUID) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(GitHubAccountStore.self) private var gitHubAccounts
    @Environment(MailAccountStore.self) private var mailAccounts
    @Environment(ActivityLog.self) private var activityLog
    @Environment(\.mailSyncCoordinatorRegistry) private var mailRegistry: MailSyncCoordinatorRegistry?
    /// Mock-data mode: GitHub sign-in is off, so no real OAuth token is created or stored.
    @Environment(\.isMockDataMode) private var isMockDataMode

    @State private var model = AddProductWizardModel()
    @State private var showGitHubLogin = false
    @State private var showManualRepo = false
    @State private var showKeyImporter = false
    @State private var emailTest: EmailTest = .idle
    @State private var promptCopied = false
    @State private var isCreating = false

    private enum EmailTest: Equatable { case idle, running, ok, failed(String) }

    var body: some View {
        content
            .onAppear {
                model.existingRepoKeys = Set(store.products.map { "\($0.owner)/\($0.repo)".lowercased() })
            }
            .sheet(isPresented: $showGitHubLogin) {
                GitHubLoginView(accountStore: gitHubAccounts)
            }
            .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: p8Types) { result in
                if case .success(let url) = result { model.appStore.importPEM(from: url) }
            }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 4)
            stepForm
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !model.isFirstStep {
                    Button("Back") { move(forward: false) }
                }
                primaryButton
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(16)
        }
        .frame(width: 560, height: 640)
        #else
        NavigationStack {
            stepForm
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if model.isFirstStep {
                            Button("Cancel") { dismiss() }
                        } else {
                            Button { move(forward: false) } label: {
                                Label("Back", systemImage: "chevron.backward")
                            }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) { primaryButton }
                }
        }
        #endif
    }

    @ViewBuilder
    private var primaryButton: some View {
        if model.isLastStep {
            Button {
                Task { await create() }
            } label: {
                if isCreating { ProgressView().controlSize(.small) } else { Text("Create Product") }
            }
            .disabled(!model.canContinue || isCreating)
        } else {
            Button("Continue") { move(forward: true) }
                .disabled(!model.canContinue)
        }
    }

    private var header: some View {
        let info = stepInfo
        return VStack(spacing: 8) {
            Image(systemName: info.symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
            Text("Step \(model.stepNumber) of \(model.steps.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(info.title)
                .font(.title2.weight(.semibold))
            Text(info.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var tint: Color { model.colorHex.map(Color.init(hex:)) ?? .accentColor }

    private var stepForm: some View {
        Form {
            #if os(iOS)
            Section { header }
                .listRowBackground(Color.clear)
            #endif
            stepContent
        }
        .formStyle(.grouped)
        .id(model.step)
        .transition(.push(from: model.movedForward ? .trailing : .leading))
    }

    private func move(forward: Bool) {
        withAnimation(.snappy) {
            if forward { model.goForward() } else { model.goBack() }
        }
    }

    // MARK: - Steps

    private var stepInfo: (symbol: String, title: String, subtitle: String) {
        switch model.step {
        case .sources:
            ("tray.and.arrow.down.fill", "New Product",
             "Choose where this product's feedback comes from. Pick any combination.")
        case .repository:
            ("externaldrive.fill.badge.checkmark", "GitHub Repository",
             model.sources == [.sdk]
                ? "The repository your app sends feedback to."
                : "Love Letter files every piece of feedback as an issue in this repository.")
        case .appStore:
            ("star.bubble.fill", "App Store Reviews",
             "Connect an App Store Connect API key to read reviews and reply from Love Letter.")
        case .email:
            ("envelope.fill", "Feedback Inbox",
             "Connect a mailbox dedicated to feedback. Each new email becomes a feedback item.")
        case .sdk:
            ("hammer.fill", "Add the SDK to Your App",
             "Let people send bug reports and feature requests from inside your app.")
        case .summary:
            ("checkmark.seal.fill", "Review", "Name your product and check everything's right.")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .sources:    sourcesStep
        case .repository: repositoryStep
        case .appStore:   appStoreStep
        case .email:      emailStep
        case .sdk:        sdkStep
        case .summary:    summaryStep
        }
    }

    // MARK: Sources

    private var sourcesStep: some View {
        Section {
            sourceToggle(.sdk, title: "In-App Feedback", systemImage: "hammer",
                         detail: "Reports sent from your app with the Love Letter SDK")
            sourceToggle(.appStore, title: "App Store Reviews", systemImage: "star.bubble",
                         detail: "Ratings and reviews, with replies from Love Letter")
            sourceToggle(.email, title: "Email", systemImage: "envelope",
                         detail: "Messages sent to a dedicated feedback address")
        } footer: {
            Text("You can add or remove sources later in the product's settings.")
        }
    }

    private func sourceToggle(_ source: AddProductWizardModel.Source, title: String,
                              systemImage: String, detail: String) -> some View {
        Toggle(isOn: Binding(
            get: { model.sources.contains(source) },
            set: { on in
                if on { model.sources.insert(source) } else { model.sources.remove(source) }
            }
        )) {
            Label {
                Text(title)
                Text(detail)
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }

    // MARK: Repository

    @ViewBuilder
    private var repositoryStep: some View {
        if gitHubAccounts.accounts.isEmpty {
            Section {
                Button {
                    showGitHubLogin = true
                } label: {
                    Label("Sign in with GitHub", systemImage: "person.badge.key.fill")
                }
                .disabled(isMockDataMode)
            } footer: {
                Text(isMockDataMode
                     ? "GitHub sign-in is off while using mock data. Enter the repository manually below."
                     : "Sign in to pick from your repositories, or enter one manually below.")
            }
        } else {
            Section {
                AccountRepoPicker(
                    accounts: gitHubAccounts.accounts,
                    accountStore: gitHubAccounts,
                    existingRepoKeys: model.existingRepoKeys,
                    selectedKey: model.selectedRepoKey,
                    onSelect: { account, ghRepo in
                        model.owner = ghRepo.owner.login
                        model.repo = ghRepo.name
                        model.token = gitHubAccounts.token(for: account) ?? ""
                        model.repoIsPrivate = ghRepo.isPrivate
                    },
                    onConnectAnother: { if !isMockDataMode { showGitHubLogin = true } }
                )
                .listRowInsets(EdgeInsets())
            }
        }

        Section {
            DisclosureGroup("Enter Manually", isExpanded: $showManualRepo) {
                TextField("Owner", text: manualBinding(\.owner), prompt: Text("owner"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("Repository", text: manualBinding(\.repo), prompt: Text("repo-name"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Token", text: $model.token, prompt: Text("ghp_…"))
            }
        } footer: {
            if model.isDuplicateRepository {
                Label("\(model.owner)/\(model.repo) is already a product.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if showManualRepo {
                Text("The token needs read and write access to the repository's issues. It's stored in your Keychain.")
            }
        }
    }

    /// Manual edits clear the picked repo's privacy flag — it's unknown for a typed-in repo.
    private func manualBinding(_ keyPath: ReferenceWritableKeyPath<AddProductWizardModel, String>) -> Binding<String> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0; model.repoIsPrivate = nil }
        )
    }

    // MARK: App Store

    @ViewBuilder
    private var appStoreStep: some View {
        let asc = model.appStore
        Section {
            TextField("Issuer ID", text: Bindable(asc).issuerID)
                .autocorrectionDisabled()
            TextField("Key ID", text: Bindable(asc).keyID)
                .autocorrectionDisabled()
            LabeledContent("Private Key") {
                Button(asc.pemText.isEmpty ? "Import .p8 File…" : "Replace…") { showKeyImporter = true }
            }
            if !asc.pemText.isEmpty {
                Label("Key imported", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("The .p8 key is stored only in your Keychain.")
        }

        Section("App") {
            switch asc.phase {
            case .valid where !asc.discoveredApps.isEmpty:
                Picker("App", selection: Bindable(asc).selectedAppID) {
                    ForEach(asc.discoveredApps, id: \.id) { app in
                        Text(app.name).tag(app.id as String?)
                    }
                }
            default:
                Button {
                    Task { await verifyAppStoreKey() }
                } label: {
                    HStack {
                        Text("Verify Key & Load Apps")
                        if asc.phase == .testing { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(asc.issuerID.isEmpty || asc.keyID.isEmpty || asc.pemText.isEmpty || asc.phase == .testing)
                if case .failed(let message) = asc.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }

        Section { AppStoreKeyHelp() }
    }

    private var p8Types: [UTType] {
        var types: [UTType] = [.data, .text]
        if let p8 = UTType(filenameExtension: "p8") { types.insert(p8, at: 0) }
        return types
    }

    private func verifyAppStoreKey() async {
        await model.appStore.test { issuer, kid, pem in
            AppStoreConnectClient(auth: AppStoreConnectAuth(issuerID: issuer, keyID: kid, p8PEM: pem),
                                  activityLog: activityLog)
        }
    }

    // MARK: Email

    @ViewBuilder
    private var emailStep: some View {
        let mail = model.email
        Section {
            Picker("Service", selection: Binding(get: { mail.preset }, set: { mail.applyPresetDefaults($0); emailTest = .idle })) {
                ForEach(SMTPCredentials.Preset.allCases) { Text($0.displayName).tag($0) }
            }
            TextField("Address", text: Binding(get: { mail.username }, set: { mail.username = $0; emailTest = .idle }),
                      prompt: Text("feedback@yourapp.com"))
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
            SanitizedPasswordField(
                title: "Password",
                prompt: Text(mail.preset.passwordPrompt),
                text: Binding(get: { mail.password }, set: { mail.password = mail.preset.sanitize(password: $0); emailTest = .idle })
            )
            if let help = mail.preset.help {
                MailProviderHintCard(preset: mail.preset, help: help,
                                     appPasswordURL: mail.preset.appPasswordsURL(forEmail: mail.username))
            }
        }

        if mail.preset == .custom {
            Section("Server") {
                TextField("IMAP Host", text: Bindable(mail).imapHost)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("IMAP Port", text: Bindable(mail).imapPort)
                TextField("SMTP Host", text: Bindable(mail).smtpHost)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("SMTP Port", text: Bindable(mail).smtpPort)
            }
        }

        Section {
            Button {
                Task { await testEmail() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    switch emailTest {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }
            .disabled(!mail.canTest || emailTest == .running)
            if case .failed(let message) = emailTest {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            EmailSetupHelp(preset: mail.preset, username: mail.username)
        }
    }

    private func testEmail() async {
        let mail = model.email
        emailTest = .running
        let logID = activityLog.start(kind: .testConnection, title: "\(mail.imapHost):\(mail.imapPort)")
        #if canImport(SwiftMail)
        do {
            try await IMAPClient(host: mail.imapHost, port: Int(mail.imapPort) ?? 993,
                                 username: mail.username, password: mail.password).testConnection()
            activityLog.finish(logID, status: .success, detail: "Login OK")
            emailTest = .ok
        } catch {
            let message = MailErrorTranslator.describe(error, preset: mail.preset)
            activityLog.finish(logID, status: .failure, detail: message)
            emailTest = .failed(message)
        }
        #else
        activityLog.finish(logID, status: .failure, detail: "SwiftMail not available")
        emailTest = .failed("Email isn't available in this build.")
        #endif
    }

    // MARK: SDK

    @ViewBuilder
    private var sdkStep: some View {
        Section {
            Button {
                copyPrompt()
            } label: {
                Label(promptCopied ? "Copied" : "Copy Setup Prompt",
                      systemImage: promptCopied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
        } header: {
            Text("Set Up with an AI Agent")
        } footer: {
            Text("Paste the prompt into Claude Code, Codex or Cursor in your app's project. It adds the SDK and points it at \(model.owner)/\(model.repo).")
        }

        Section {
            Link(destination: URL(string: "https://hayek.github.io/loveletter-docs/")!) {
                Label("SDK Documentation", systemImage: "book")
            }
        } footer: {
            Text("Available for Apple platforms, Android and the web. You can do this any time.")
        }
    }

    private func copyPrompt() {
        let text = SDKIntegrationPrompt.text(owner: model.owner, repo: model.repo)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        withAnimation { promptCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { promptCopied = false }
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var summaryStep: some View {
        Section {
            TextField("Name", text: $model.name, prompt: Text(model.suggestedName))
        }

        Section("Color") {
            ColorSwatchPicker(selection: $model.colorHex)
        }

        Section("Feedback From") {
            if model.sources.contains(.sdk) {
                summaryRow("In-App Feedback", systemImage: "hammer", value: "Love Letter SDK")
            }
            if model.sources.contains(.appStore) {
                summaryRow("App Store Reviews", systemImage: "star.bubble",
                           value: model.selectedApp?.name ?? "App \(model.appStore.resolvedAppAppleID() ?? "")")
            }
            if model.sources.contains(.email) {
                summaryRow("Email", systemImage: "envelope", value: model.email.username)
            }
        }

        Section {
            summaryRow("Repository", systemImage: "externaldrive", value: "\(model.owner)/\(model.repo)")
        } footer: {
            Text("Everything else, like mirroring email replies to GitHub, can be changed later in the product's settings.")
        }
    }

    private func summaryRow(_ title: String, systemImage: String, value: String) -> some View {
        LabeledContent {
            Text(value).lineLimit(1).truncationMode(.middle)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    // MARK: - Create

    private func create() async {
        guard !isCreating else { return }
        isCreating = true
        defer { isCreating = false }

        // Secrets first, so the loaders and coordinators that react to the new product find them.
        var inboxAccountID: UUID?
        if model.sources.contains(.email) {
            let mail = model.email
            if mail.senderName.isEmpty { mail.senderName = model.makeConfig().displayName }
            let v = mail.effectiveAccountValues()
            let account = mailAccounts.add { acc in
                acc.presetRaw = v.presetRaw
                acc.imapHost = v.imapHost; acc.imapPort = v.imapPort; acc.imapUsername = v.imapUsername
                acc.smtpHost = v.smtpHost; acc.smtpPort = v.smtpPort; acc.smtpUsername = v.smtpUsername
                acc.senderName = v.senderName
                acc.pollingEnabled = v.pollingEnabled
                acc.feedbackProductID = v.feedbackProductID
            }
            _ = await KeychainService.saveIMAPPassword(mail.password, for: account.id)
            _ = await KeychainService.saveSMTPPassword(mail.password, for: account.id)
            inboxAccountID = account.id
        }
        if model.sources.contains(.appStore) {
            _ = await KeychainService.saveASCKey(model.appStore.pemText, for: model.productID)
        }

        let product = model.makeConfig(feedbackInboxAccountID: inboxAccountID)
        await KeychainService.save(token: model.token.trimmingCharacters(in: .whitespacesAndNewlines), for: product)
        // Adding the product also starts its App Store coordinator (LoveLetterApp syncs on product ids).
        store.add(product)
        if inboxAccountID != nil { mailRegistry?.syncWithAccounts() }

        onCreated(product.id)
        dismiss()
    }
}

/// A row of the product accent swatches, plus "none" for the default color.
private struct ColorSwatchPicker: View {
    @Binding var selection: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 4)], spacing: 6) {
            swatch(hex: nil)
            ForEach(ColorPalette.swatches, id: \.self) { swatch(hex: $0.hex) }
        }
        .padding(.vertical, 2)
    }

    private func swatch(hex: String?) -> some View {
        let isSelected = selection == hex
        return Button {
            withAnimation(.snappy) { selection = hex }
        } label: {
            Group {
                if let hex {
                    Circle().fill(Color(hex: hex).gradient)
                } else {
                    Image(systemName: "circle.slash")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .padding(3)
            .overlay {
                Circle().strokeBorder(isSelected ? Color.primary.opacity(0.6) : .clear, lineWidth: 2)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(hex.flatMap(ColorPalette.name(forHex:)) ?? "Default")
        .accessibilityLabel(hex.flatMap(ColorPalette.name(forHex:)) ?? "Default color")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

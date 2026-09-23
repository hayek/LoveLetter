import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Step-by-step "Add Product" flow: connect the GitHub repository every source files into, then
/// set up or skip each feedback source in turn (the SDK, App Store reviews, an email inbox), then
/// review, name and tint the product.
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
    @State private var showKeyImporter = false
    @State private var emailTest: EmailTest = .idle
    @State private var promptCopied = false
    @State private var isCreating = false
    @State private var createError: String?

    private enum EmailTest: Equatable { case idle, running, ok, failed(String) }

    var body: some View {
        content
            .onAppear {
                model.existingRepoKeys = Set(store.products.map { "\($0.owner)/\($0.repo)".lowercased() })
            }
            .alert("Couldn't Create Product", isPresented: Binding(
                get: { createError != nil }, set: { if !$0 { createError = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(createError ?? "")
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
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
            stepForm
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !model.isFirstStep {
                    Button("Back") { move(forward: false) }
                }
                if model.canSkip {
                    Button("Skip") { skip() }
                }
                primaryButton
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(16)
        }
        .frame(width: 580, height: 620)
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
                    if model.canSkip {
                        ToolbarItem(placement: .bottomBar) {
                            Button("Skip") { skip() }
                        }
                    }
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
            Button {
                if model.step == .repository && model.createsRepository {
                    Task { await continueAfterCheckingNewRepository() }
                } else {
                    move(forward: true)
                }
            } label: {
                if model.isCheckingNewRepo { ProgressView().controlSize(.small) } else { Text("Continue") }
            }
            .disabled(!model.canContinue)
        }
    }

    private var header: some View {
        let info = stepInfo
        return VStack(alignment: .leading, spacing: 14) {
            StepProgressBar(count: model.steps.count, current: model.stepNumber, tint: tint)
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: info.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(info.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tint: Color { model.colorHex.map(Color.init(hex:)) ?? .accentColor }

    /// The ZStack keeps the outgoing and incoming step overlapped while they swap (in the macOS
    /// VStack they'd otherwise split the height). Only the insertion is directional: a removed
    /// view keeps the transition from its last render, which points the wrong way right after
    /// the user reverses direction.
    private var stepForm: some View {
        ZStack {
            Form {
                #if os(iOS)
                Section { header }
                    .listRowBackground(Color.clear)
                #endif
                stepContent
            }
            .formStyle(.grouped)
            .id(model.step)
            .transition(.asymmetric(insertion: .push(from: model.movedForward ? .trailing : .leading),
                                    removal: .opacity))
        }
        .clipped()
    }

    /// Continue from the repository step once the new repository's name is known to be free.
    /// The step check keeps a second tap that lands during the check from advancing twice.
    private func continueAfterCheckingNewRepository() async {
        guard await model.verifyNewRepository(), model.step == .repository else { return }
        move(forward: true)
    }

    private func skip() {
        withAnimation(.snappy) { model.skip() }
    }

    private func move(forward: Bool) {
        withAnimation(.snappy) {
            if forward { model.goForward() } else { model.goBack() }
        }
    }

    // MARK: - Steps

    private var stepInfo: (symbol: String, title: String, subtitle: String) {
        switch model.step {
        case .repository:
            ("externaldrive.fill.badge.checkmark", "Repository",
             "Feedback from every source is kept in a GitHub repository, as issues.")
        case .sdk:
            ("hammer.fill", "In-App Feedback",
             "Let people send bug reports and feature requests from inside your app.")
        case .appStore:
            ("star.bubble.fill", "App Store Reviews",
             "Read reviews and reply to them with an App Store Connect API key.")
        case .email:
            ("envelope.fill", "Email",
             "Each email to a dedicated feedback address becomes a feedback item.")
        case .summary:
            ("checkmark.seal.fill", "Review", "Name the product and check everything's right.")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .repository: repositoryStep
        case .appStore:   appStoreStep
        case .email:      emailStep
        case .sdk:        sdkStep
        case .summary:    summaryStep
        }
    }

    // MARK: Repository

    private var repositoryStep: some View {
        WizardRepositoryStep(model: model, accountStore: gitHubAccounts, isMockDataMode: isMockDataMode,
                             onConnectAccount: { if !isMockDataMode { showGitHubLogin = true } })
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
                Button(asc.pemText.isEmpty ? "Import .p8 Key…" : "Replace…") { showKeyImporter = true }
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
                } else if asc.phase == .valid {
                    Label("The key works but can't see any apps.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if model.appStoreNeedsManualAppID {
                    // Fallback: the numeric Apple ID from the app's App Information page.
                    TextField("Apple ID", text: Bindable(asc).manualAppID, prompt: Text("Numeric app ID"))
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
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
            Text("Paste the prompt into Claude Code, Codex or Cursor in your app's project. It adds the SDK and points it at \(model.repoFullName).")
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
        let text = SDKIntegrationPrompt.text(owner: model.owner.trimmingCharacters(in: .whitespacesAndNewlines),
                                             repo: model.repo.trimmingCharacters(in: .whitespacesAndNewlines))
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

        Section {
            summaryRow("Repository", systemImage: "externaldrive",
                       value: model.createsRepository ? "\(model.repoFullName) (new)" : model.repoFullName)
            summaryRow("In-App Feedback", systemImage: "hammer",
                       value: model.sources.contains(.sdk) ? "Love Letter SDK" : nil)
            summaryRow("App Store Reviews", systemImage: "star.bubble",
                       value: model.sources.contains(.appStore)
                           ? model.selectedApp?.name ?? "App \(model.appStore.resolvedAppAppleID() ?? "")"
                           : nil)
            summaryRow("Email", systemImage: "envelope",
                       value: model.sources.contains(.email) ? model.email.username : nil)
        } header: {
            Text("Feedback")
        } footer: {
            Text("You can set up skipped sources, and options like mirroring email replies to GitHub, later in the product's settings.")
        }
    }

    /// A nil `value` marks a skipped source.
    private func summaryRow(_ title: String, systemImage: String, value: String?) -> some View {
        LabeledContent {
            Text(value ?? "Skipped")
                .foregroundStyle(value == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    // MARK: - Create

    private func create() async {
        guard !isCreating else { return }
        isCreating = true
        defer { isCreating = false }

        // Adding the product also starts its App Store coordinator (LoveLetterApp syncs on product ids).
        do {
            let product = try await model.create(products: store, mailAccounts: mailAccounts, mailRegistry: mailRegistry)
            onCreated(product.id)
            dismiss()
        } catch {
            createError = error is ProductSetup.CreateRepositoryError
                ? error.localizedDescription
                : "GitHub couldn't create \(model.repoFullName): \(error.localizedDescription)"
        }
    }
}

/// A segmented bar showing how far through the wizard the user is.
private struct StepProgressBar: View {
    let count: Int
    let current: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
                    .frame(height: 4)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current) of \(count)")
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

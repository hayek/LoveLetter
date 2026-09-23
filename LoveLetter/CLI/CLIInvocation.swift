#if os(macOS)
import Foundation

struct CLIUsageError: Error, Equatable {
    let code: String        // missing_flag | unknown_flag | bad_value | missing_value | conflicting_flags
                            // | confirmation_required
    let message: String
    var hint: String?
}

enum CLIState: String, CaseIterable { case open, closed, all }
enum CLISort: String, CaseIterable { case created, updated }
enum CLIOrder: String, CaseIterable { case desc, asc }
enum CLIChannel: String, CaseIterable { case auto, email, appStore = "app-store", comment }
enum CLISwitch: String, CaseIterable { case on, off }

struct CLIFlags {
    var product: String = ""
    var labels: [String] = []
    var sources: [FeedbackSource] = []
    var statuses: [TaskStatus] = []
    var priorities: [TaskPriority] = []
    var state: CLIState = .open
    var search: String?
    var since: Date?
    var updatedSince: Date?
    var minRating: Int?
    var maxRating: Int?
    var appVersion: String?
    var version: String?
    var hasTask: Bool?              // nil = no constraint
    var unread: Bool?               // nil = no constraint
    var includeEmails = false
    var raw = false
    var refresh = false
    var json = true
    var limit = 20
    var offset = 0
    var sort: CLISort = .created
    var order: CLIOrder = .desc
    var timeout: TimeInterval = 30
    /// False while `timeout` is still the default, so slow commands can pick a longer one.
    var timeoutExplicit = false

    // Write-command payload
    var title: String?
    var notes: String?
    var body: String?
    var template: String?
    var channel: CLIChannel = .auto
    var taskNumber: Int?
    var feedbackNumbers: [Int] = []
    /// Acknowledges a destructive or outward-facing write (remove, delete, release…).
    var yes = false

    // products add / update
    var repo: String?               // owner/repo
    var name: String?
    /// Resolved hex (no `#`), or "" for the default color. nil = leave unchanged.
    var colorHex: String?
    var mirrorEmails: Bool?
    var redactEmails: Bool?
    var tokenStdin = false
    var account: String?            // a connected GitHub account's login
    /// products add: create the repository on GitHub (private unless `publicRepo`).
    var createRepo = false
    var publicRepo = false

    // products app-store
    var issuerID: String?
    var keyID: String?
    var p8Path: String?
    var appID: String?

    // products email
    var preset: SMTPCredentials.Preset?
    var address: String?
    var passwordStdin = false
    var senderName: String?
    var imapHost: String?
    var imapPort: Int?
    var smtpHost: String?
    var smtpPort: Int?
    var skipTest = false
    var remove = false

    // tasks update
    var noVersion = false

    // versions
    var changelog: String?
    var subject: String?
    var recipients: [String] = []
    var skipRecipients: [String] = []
    var resend = false
    var noEmail = false

    // feedback mark-read / triage, respond --delete
    var all = false
    var accept = false
    var dismiss = false
    var delete = false
}

enum CLIProductVerb {
    case list(CLIFlags), add(CLIFlags), update(CLIFlags), remove(CLIFlags)
    case appStore(CLIFlags), email(CLIFlags)
}

enum CLIFeedbackVerb {
    case list(CLIFlags), show(Int, CLIFlags)
    case markRead(CLIFlags), triage(CLIFlags)
}

enum CLITaskVerb {
    case list(CLIFlags), show(Int, CLIFlags)
    case create(CLIFlags), update(CLIFlags), delete(CLIFlags)
    case link(CLIFlags), unlink(CLIFlags)
}

enum CLIVersionVerb {
    case list(CLIFlags), show(CLIFlags), recipients(CLIFlags)
    case create(CLIFlags), update(CLIFlags), delete(CLIFlags), release(CLIFlags)
}

enum CLITemplateVerb {
    case list(CLIFlags), create(CLIFlags), update(CLIFlags), delete(CLIFlags)
}

enum CLICommand {
    case products(CLIProductVerb)
    case feedback(CLIFeedbackVerb)
    case tasks(CLITaskVerb)
    case versions(CLIVersionVerb)
    case templates(CLITemplateVerb)
    case respond(CLIFlags)
    case accounts(CLIFlags)
    case help(String?)
    case version

    /// The flags the command runs with; nil for help and version.
    var flags: CLIFlags? {
        switch self {
        case .products(let verb):
            switch verb {
            case .list(let f), .add(let f), .update(let f), .remove(let f), .appStore(let f), .email(let f):
                return f
            }
        case .feedback(let verb):
            switch verb {
            case .list(let f), .show(_, let f), .markRead(let f), .triage(let f): return f
            }
        case .tasks(let verb):
            switch verb {
            case .list(let f), .show(_, let f), .create(let f), .update(let f), .delete(let f),
                 .link(let f), .unlink(let f):
                return f
            }
        case .versions(let verb):
            switch verb {
            case .list(let f), .show(let f), .recipients(let f), .create(let f), .update(let f),
                 .delete(let f), .release(let f):
                return f
            }
        case .templates(let verb):
            switch verb {
            case .list(let f), .create(let f), .update(let f), .delete(let f): return f
            }
        case .respond(let f), .accounts(let f): return f
        case .help, .version: return nil
        }
    }
}

enum CLIInvocation {
    static let maxLimit = 200
    /// Default wait for writes that talk to a mail server or App Store Connect before answering.
    static let slowWriteTimeout: TimeInterval = 90
    /// Default wait for `versions release`, which emails every recipient one by one.
    static let releaseTimeout: TimeInterval = 600
    private static let nouns: Set<String> = ["products", "feedback", "tasks", "respond",
                                             "versions", "templates", "accounts"]

    /// nil ⇒ not a CLI invocation (run the GUI). `.failure` ⇒ a CLI invocation that is
    /// malformed. The distinction is load-bearing: the dispatcher runs the GUI for nil and
    /// prints a usage error for `.failure`.
    static func parse(_ argv: [String], now: Date = Date()) -> Result<CLICommand, CLIUsageError>? {
        let args = Array(argv.dropFirst())
        guard let first = args.first else { return nil }

        if first == "--version" || first == "version" { return .success(.version) }
        if first == "--help" || first == "-h" || first == "help" {
            return .success(.help(args.count > 1 ? args[1] : nil))
        }
        guard nouns.contains(first) else { return nil }

        let rest = Array(args.dropFirst())
        // `<noun> [verb] --help` is help for that noun, whatever else was typed.
        if rest.contains("--help") || rest.contains("-h") { return .success(.help(first)) }
        do {
            switch first {
            case "products":
                return .success(try parseProducts(rest, now: now))
            case "feedback":
                return .success(try parseFeedback(rest, now: now))
            case "tasks":
                return .success(try parseTasks(rest, now: now))
            case "versions":
                return .success(try parseVersions(rest, now: now))
            case "templates":
                return .success(try parseTemplates(rest, now: now))
            case "respond":
                return .success(try parseRespond(rest, now: now))
            case "accounts":
                return .success(.accounts(try parseFlags(rest, now: now)))
            default:
                return nil
            }
        } catch let error as CLIUsageError {
            return .failure(error)
        } catch {
            return .failure(CLIUsageError(code: "usage", message: error.localizedDescription))
        }
    }

    // MARK: - Per-noun grammar

    private static func parseProducts(_ args: [String], now: Date) throws -> CLICommand {
        let (verb, _, rest) = splitVerb(args, verbs: ["list", "add", "update", "remove",
                                                      "app-store", "email"])
        var flags = try parseFlags(rest, now: now)
        switch verb {
        case "add":
            guard let repo = flags.repo else {
                throw CLIUsageError(code: "missing_flag", message: "products add requires --repo owner/repo")
            }
            guard let (_, name) = parseRepo(repo) else {
                throw CLIUsageError(code: "bad_value", message: "--repo must look like owner/repo")
            }
            if flags.createRepo && !ProductSetup.isValidRepositoryName(name) {
                throw CLIUsageError(code: "bad_value",
                                    message: "'\(name)' isn't a valid repository name",
                                    hint: "Use only letters, numbers, hyphens, underscores and periods.")
            }
            if flags.publicRepo && !flags.createRepo {
                throw CLIUsageError(code: "conflicting_flags", message: "--public only applies with --create-repo")
            }
            try requireSingleTokenSource(flags)
            return .products(.add(flags))
        case "update":
            flags = try requireProduct(flags)
            try requireSingleTokenSource(flags)
            let changes: [Any?] = [flags.name, flags.colorHex, flags.mirrorEmails, flags.redactEmails,
                                   flags.account]
            guard changes.contains(where: { $0 != nil }) || flags.tokenStdin else {
                throw CLIUsageError(code: "missing_flag", message: "products update needs something to change",
                                    hint: "--name, --color, --mirror-emails, --redact-emails, --token-stdin or --account")
            }
            return .products(.update(flags))
        case "remove":
            flags = try requireConfirmation(requireProduct(flags),
                                            "Removing a product deletes it and its GitHub token from Love Letter.")
            return .products(.remove(flags))
        case "app-store":
            flags = try requireProduct(flags)
            for (value, name) in [(flags.issuerID, "--issuer-id"), (flags.keyID, "--key-id"), (flags.p8Path, "--p8")]
            where value?.isEmpty != false {
                throw CLIUsageError(code: "missing_flag", message: "products app-store requires \(name)")
            }
            if let appID = flags.appID, appID.isEmpty || !appID.allSatisfy(\.isNumber) {
                throw CLIUsageError(code: "bad_value", message: "--app-id is the numeric App Store Connect app id")
            }
            if !flags.timeoutExplicit { flags.timeout = slowWriteTimeout }
            return .products(.appStore(flags))
        case "email":
            flags = try requireProduct(flags)
            if flags.remove {
                return .products(.email(try requireConfirmation(flags,
                    "Removing the email source stops fetching the inbox and deletes its credentials.")))
            }
            guard flags.preset != nil else {
                throw CLIUsageError(code: "missing_flag", message: "products email requires --preset",
                                    hint: "one of: \(SMTPCredentials.Preset.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            guard flags.address?.isEmpty == false else {
                throw CLIUsageError(code: "missing_flag", message: "products email requires --address")
            }
            guard flags.passwordStdin else {
                throw CLIUsageError(code: "missing_flag", message: "products email requires --password-stdin",
                                    hint: "Pipe the password in, e.g. `security find-generic-password -w … | "
                                        + "\(CLIBranding.commandName) products email … --password-stdin`.")
            }
            if flags.preset == .custom, flags.imapHost?.isEmpty != false || flags.smtpHost?.isEmpty != false {
                throw CLIUsageError(code: "missing_flag",
                                    message: "--preset custom requires --imap-host and --smtp-host")
            }
            if !flags.timeoutExplicit { flags.timeout = slowWriteTimeout }
            return .products(.email(flags))
        default:
            return .products(.list(flags))
        }
    }

    private static func parseFeedback(_ args: [String], now: Date) throws -> CLICommand {
        let (verb, number, rest) = splitVerb(args, verbs: ["list", "show", "mark-read", "triage"])
        let flags = try requireProduct(try parseFlags(rest, now: now))
        switch verb {
        case "show":
            guard let number else {
                throw CLIUsageError(code: "missing_value", message: "feedback show needs an issue number")
            }
            return .feedback(.show(number, flags))
        case "mark-read":
            guard flags.all != !flags.feedbackNumbers.isEmpty else {
                throw CLIUsageError(code: flags.all ? "conflicting_flags" : "missing_flag",
                                    message: "feedback mark-read takes either --feedback 12,34 or --all")
            }
            return .feedback(.markRead(flags))
        case "triage":
            guard flags.feedbackNumbers.count == 1 else {
                throw CLIUsageError(code: "missing_flag",
                                    message: "feedback triage requires exactly one --feedback <number>")
            }
            guard flags.accept != flags.dismiss else {
                throw CLIUsageError(code: flags.accept ? "conflicting_flags" : "missing_flag",
                                    message: "feedback triage takes either --accept or --dismiss")
            }
            return .feedback(.triage(flags))
        default:
            return .feedback(.list(flags))
        }
    }

    private static func parseTasks(_ args: [String], now: Date) throws -> CLICommand {
        let (verb, number, rest) = splitVerb(args, verbs: ["list", "show", "create", "update", "delete",
                                                           "link", "unlink"])
        var flags = try requireProduct(try parseFlags(rest, now: now))
        switch verb {
        case "show":
            guard let number else {
                throw CLIUsageError(code: "missing_value", message: "tasks show needs a task number")
            }
            return .tasks(.show(number, flags))
        case "create":
            guard flags.title?.isEmpty == false else {
                throw CLIUsageError(code: "missing_flag", message: "tasks create requires --title")
            }
            return .tasks(.create(flags))
        case "update":
            flags.taskNumber = flags.taskNumber ?? number
            guard flags.taskNumber != nil else {
                throw CLIUsageError(code: "missing_flag", message: "tasks update requires --task")
            }
            guard flags.statuses.count <= 1, flags.priorities.count <= 1 else {
                throw CLIUsageError(code: "bad_value", message: "tasks update takes one --status and one --priority")
            }
            if flags.version != nil && flags.noVersion {
                throw CLIUsageError(code: "conflicting_flags", message: "--version and --no-version are mutually exclusive")
            }
            if flags.title?.isEmpty == true {
                throw CLIUsageError(code: "bad_value", message: "--title cannot be empty")
            }
            let changes: [Any?] = [flags.title, flags.notes, flags.statuses.first, flags.priorities.first,
                                   flags.version]
            guard changes.contains(where: { $0 != nil }) || flags.noVersion else {
                throw CLIUsageError(code: "missing_flag", message: "tasks update needs something to change",
                                    hint: "--title, --notes, --status, --priority, --version or --no-version")
            }
            return .tasks(.update(flags))
        case "delete":
            flags.taskNumber = flags.taskNumber ?? number
            guard flags.taskNumber != nil else {
                throw CLIUsageError(code: "missing_flag", message: "tasks delete requires --task")
            }
            return .tasks(.delete(try requireConfirmation(flags,
                "Deleting a task permanently deletes its GitHub issue.")))
        case "link", "unlink":
            guard flags.taskNumber != nil else {
                throw CLIUsageError(code: "missing_flag", message: "tasks \(verb) requires --task")
            }
            guard !flags.feedbackNumbers.isEmpty else {
                throw CLIUsageError(code: "missing_flag", message: "tasks \(verb) requires --feedback")
            }
            return .tasks(verb == "link" ? .link(flags) : .unlink(flags))
        default:
            return .tasks(.list(flags))
        }
    }

    private static func parseVersions(_ args: [String], now: Date) throws -> CLICommand {
        let (verb, _, rest) = splitVerb(args, verbs: ["list", "show", "recipients", "create", "update",
                                                      "delete", "release"])
        var flags = try requireProduct(try parseFlags(rest, now: now))
        if verb != "list", flags.version?.isEmpty != false {
            throw CLIUsageError(code: "missing_flag", message: "versions \(verb) requires --version <name>")
        }
        switch verb {
        case "show":       return .versions(.show(flags))
        case "recipients": return .versions(.recipients(flags))
        case "create":     return .versions(.create(flags))
        case "update":
            guard flags.name != nil || flags.title != nil || flags.changelog != nil else {
                throw CLIUsageError(code: "missing_flag", message: "versions update needs something to change",
                                    hint: "--name (renames), --title or --changelog")
            }
            if flags.name?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                throw CLIUsageError(code: "bad_value", message: "--name cannot be empty")
            }
            return .versions(.update(flags))
        case "delete":
            return .versions(.delete(try requireConfirmation(flags,
                "Deleting a version deletes its GitHub milestone. Tasks are kept.")))
        case "release":
            if flags.noEmail && (!flags.recipients.isEmpty || !flags.skipRecipients.isEmpty || flags.resend
                                 || flags.subject != nil || flags.body != nil) {
                throw CLIUsageError(code: "conflicting_flags",
                                    message: "--no-email cannot be combined with recipient or message flags")
            }
            flags = try requireConfirmation(flags,
                "Releasing emails every recipient, closes the milestone and publishes the GitHub release "
                    + "(with no mail account in Love Letter it only closes the milestone). It cannot be undone.",
                hint: "Preview with `\(CLIBranding.commandName) versions recipients`, show the user, "
                    + "then re-run with --yes.")
            if !flags.timeoutExplicit { flags.timeout = releaseTimeout }
            return .versions(.release(flags))
        default:
            return .versions(.list(flags))
        }
    }

    private static func parseTemplates(_ args: [String], now: Date) throws -> CLICommand {
        let (verb, _, rest) = splitVerb(args, verbs: ["list", "create", "update", "delete"])
        let flags = try requireProduct(try parseFlags(rest, now: now))
        switch verb {
        case "create":
            guard flags.title?.isEmpty == false, flags.body?.isEmpty == false else {
                throw CLIUsageError(code: "missing_flag", message: "templates create requires --title and --body")
            }
            return .templates(.create(flags))
        case "update":
            guard flags.template?.isEmpty == false else {
                throw CLIUsageError(code: "missing_flag", message: "templates update requires --template <title>")
            }
            guard flags.title?.isEmpty == false || flags.body?.isEmpty == false else {
                throw CLIUsageError(code: "missing_flag", message: "templates update needs --title or --body")
            }
            return .templates(.update(flags))
        case "delete":
            guard flags.template?.isEmpty == false else {
                throw CLIUsageError(code: "missing_flag", message: "templates delete requires --template <title>")
            }
            return .templates(.delete(try requireConfirmation(flags, "Deleting a template cannot be undone.")))
        default:
            return .templates(.list(flags))
        }
    }

    private static func parseRespond(_ args: [String], now: Date) throws -> CLICommand {
        let flags = try requireProduct(try parseFlags(args, now: now))
        guard flags.feedbackNumbers.count == 1 else {
            throw CLIUsageError(code: "missing_flag",
                                message: "respond requires exactly one --feedback <number>")
        }
        if flags.delete {
            guard flags.body == nil, flags.template == nil else {
                throw CLIUsageError(code: "conflicting_flags",
                                    message: "respond --delete takes no --body or --template")
            }
            return .respond(try requireConfirmation(flags,
                "Deleting removes the public App Store developer response."))
        }
        guard flags.body?.isEmpty == false || flags.template?.isEmpty == false else {
            throw CLIUsageError(code: "missing_flag", message: "respond requires --body or --template")
        }
        return .respond(flags)
    }

    // MARK: - Helpers

    private static func splitVerb(_ args: [String], verbs: Set<String>) -> (String, Int?, [String]) {
        var verb = "list"
        var number: Int?
        var rest = args
        if let first = rest.first, verbs.contains(first) {
            verb = first
            rest = Array(rest.dropFirst())
            if let candidate = rest.first, let parsed = Int(candidate) {
                number = parsed
                rest = Array(rest.dropFirst())
            }
        }
        return (verb, number, rest)
    }

    private static func requireProduct(_ flags: CLIFlags) throws -> CLIFlags {
        guard !flags.product.isEmpty else {
            throw CLIUsageError(code: "missing_flag", message: "--product is required",
                                hint: "run `\(CLIBranding.commandName) products` to list them")
        }
        return flags
    }

    /// Destructive and outward-facing writes need `--yes`, so an agent can't fire one by
    /// accident — the refusal says what would happen instead.
    private static func requireConfirmation(_ flags: CLIFlags, _ consequence: String,
                                            hint: String? = nil) throws -> CLIFlags {
        guard flags.yes else {
            throw CLIUsageError(code: "confirmation_required", message: consequence,
                                hint: hint ?? "Confirm with the user, then re-run with --yes.")
        }
        return flags
    }

    private static func requireSingleTokenSource(_ flags: CLIFlags) throws {
        if flags.tokenStdin && flags.account != nil {
            throw CLIUsageError(code: "conflicting_flags",
                                message: "--token-stdin and --account are mutually exclusive")
        }
    }

    /// `owner/repo`, also accepting a pasted GitHub URL or a trailing `.git`.
    static func parseRepo(_ raw: String) -> (owner: String, repo: String)? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:"]
        where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        if text.hasSuffix("/") { text = String(text.dropLast()) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !parts.joined().contains(where: \.isWhitespace) else { return nil }
        return (parts[0], parts[1])
    }

    /// A palette name (case-insensitive), a 6-digit hex with or without `#`, or `none`/`default`.
    /// Returns the stored hex, "" for the default color, or nil when unrecognised.
    static func parseColor(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if ["none", "default"].contains(text.lowercased()) { return "" }
        if let swatch = ColorPalette.swatches.first(where: {
            $0.name.compare(text, options: .caseInsensitive) == .orderedSame
        }) { return swatch.hex }
        let hex = (text.hasPrefix("#") ? String(text.dropFirst()) : text).lowercased()
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// `7d`/`24h` relative to `now`; `YYYY-MM-DD` as UTC midnight; full ISO8601.
    static func parseDate(_ raw: String, now: Date) -> Date? {
        if let unit = raw.last, "dh".contains(unit), let value = Double(raw.dropLast()) {
            return now.addingTimeInterval(-value * (unit == "d" ? 86_400 : 3_600))
        }
        if raw.count == 10 {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: raw) { return date }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    // MARK: - Flag parsing

    private static func parseFlags(_ args: [String], now: Date) throws -> CLIFlags {
        var flags = CLIFlags()
        var hasTaskSeen = false, noTaskSeen = false
        var index = 0

        func nextValue(for name: String) throws -> String {
            index += 1
            guard index < args.count else {
                throw CLIUsageError(code: "missing_value", message: "\(name) needs a value")
            }
            return args[index]
        }
        func parseEnum<T: RawRepresentable & CaseIterable>(_ name: String, _ raw: String) throws -> T
        where T.RawValue == String {
            guard let parsed = T(rawValue: raw) else {
                let valid = T.allCases.map { "\($0.rawValue)" }.joined(separator: ", ")
                throw CLIUsageError(code: "bad_value",
                                    message: "\(name): '\(raw)' is not valid. Use one of: \(valid)")
            }
            return parsed
        }
        func positiveInt(_ name: String, _ raw: String, min: Int) throws -> Int {
            guard let value = Int(raw), value >= min else {
                throw CLIUsageError(code: "bad_value", message: "\(name) must be an integer >= \(min)")
            }
            return value
        }
        func port(_ name: String) throws -> Int {
            let value = try positiveInt(name, try nextValue(for: name), min: 1)
            guard value <= 65_535 else {
                throw CLIUsageError(code: "bad_value", message: "\(name) must be a port number")
            }
            return value
        }
        func onOff(_ name: String) throws -> Bool {
            let parsed: CLISwitch = try parseEnum(name, try nextValue(for: name))
            return parsed == .on
        }

        while index < args.count {
            let arg = args[index]
            guard arg.hasPrefix("--") else {
                throw CLIUsageError(code: "unknown_flag", message: "unexpected argument '\(arg)'")
            }
            switch arg {
            case "--product":     flags.product = try nextValue(for: arg)
            case "--label":       flags.labels.append(try nextValue(for: arg))
            case "--search":      flags.search = try nextValue(for: arg)
            case "--title":       flags.title = try nextValue(for: arg)
            case "--notes":       flags.notes = try nextValue(for: arg)
            case "--body":        flags.body = try nextValue(for: arg)
            case "--template":    flags.template = try nextValue(for: arg)
            case "--version":     flags.version = try nextValue(for: arg)
            case "--app-version": flags.appVersion = try nextValue(for: arg)
            case "--repo":        flags.repo = try nextValue(for: arg)
            case "--name":        flags.name = try nextValue(for: arg)
            case "--account":     flags.account = try nextValue(for: arg)
            case "--issuer-id":   flags.issuerID = try nextValue(for: arg)
            case "--key-id":      flags.keyID = try nextValue(for: arg)
            case "--p8":          flags.p8Path = try nextValue(for: arg)
            case "--app-id":      flags.appID = try nextValue(for: arg)
            case "--address":     flags.address = try nextValue(for: arg)
            case "--sender-name": flags.senderName = try nextValue(for: arg)
            case "--imap-host":   flags.imapHost = try nextValue(for: arg)
            case "--smtp-host":   flags.smtpHost = try nextValue(for: arg)
            case "--imap-port":   flags.imapPort = try port(arg)
            case "--smtp-port":   flags.smtpPort = try port(arg)
            case "--changelog":   flags.changelog = try nextValue(for: arg)
            case "--subject":     flags.subject = try nextValue(for: arg)
            case "--recipient":   flags.recipients.append(try nextValue(for: arg))
            case "--skip":        flags.skipRecipients.append(try nextValue(for: arg))

            case "--source":   flags.sources.append(try parseEnum(arg, try nextValue(for: arg)))
            case "--status":   flags.statuses.append(try parseEnum(arg, try nextValue(for: arg)))
            case "--priority": flags.priorities.append(try parseEnum(arg, try nextValue(for: arg)))
            case "--state":    flags.state = try parseEnum(arg, try nextValue(for: arg))
            case "--sort":     flags.sort = try parseEnum(arg, try nextValue(for: arg))
            case "--order":    flags.order = try parseEnum(arg, try nextValue(for: arg))
            case "--via":      flags.channel = try parseEnum(arg, try nextValue(for: arg))
            case "--preset":   flags.preset = try parseEnum(arg, try nextValue(for: arg))

            case "--mirror-emails": flags.mirrorEmails = try onOff(arg)
            case "--redact-emails": flags.redactEmails = try onOff(arg)

            case "--color":
                let raw = try nextValue(for: arg)
                guard let hex = parseColor(raw) else {
                    let names = ColorPalette.swatches.map { $0.name.lowercased() }.joined(separator: ", ")
                    throw CLIUsageError(code: "bad_value",
                        message: "--color: '\(raw)' is not a color. Use none, a 6-digit hex, or one of: \(names)")
                }
                flags.colorHex = hex

            case "--since", "--updated-since":
                let raw = try nextValue(for: arg)
                guard let date = parseDate(raw, now: now) else {
                    throw CLIUsageError(code: "bad_value",
                        message: "\(arg): '\(raw)' is not a date. Use 7d, 24h, YYYY-MM-DD or ISO8601")
                }
                if arg == "--since" { flags.since = date } else { flags.updatedSince = date }

            case "--min-rating", "--max-rating":
                let raw = try nextValue(for: arg)
                guard let rating = Int(raw), (1...5).contains(rating) else {
                    throw CLIUsageError(code: "bad_value", message: "\(arg) must be 1-5")
                }
                if arg == "--min-rating" { flags.minRating = rating } else { flags.maxRating = rating }

            case "--limit":
                let limit = try positiveInt(arg, try nextValue(for: arg), min: 1)
                guard limit <= maxLimit else {
                    throw CLIUsageError(code: "bad_value", message: "--limit maximum is \(maxLimit)",
                                        hint: "page with --offset instead")
                }
                flags.limit = limit

            case "--offset":
                flags.offset = try positiveInt(arg, try nextValue(for: arg), min: 0)

            case "--timeout":
                let raw = try nextValue(for: arg)
                guard let seconds = Double(raw), seconds > 0 else {
                    throw CLIUsageError(code: "bad_value", message: "--timeout must be > 0")
                }
                flags.timeout = seconds
                flags.timeoutExplicit = true

            case "--task":
                flags.taskNumber = try positiveInt(arg, try nextValue(for: arg), min: 1)

            case "--feedback":
                let raw = try nextValue(for: arg)
                let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let numbers = parts.compactMap { Int($0.hasPrefix("#") ? String($0.dropFirst()) : $0) }
                guard numbers.count == parts.count, !numbers.isEmpty else {
                    throw CLIUsageError(code: "bad_value",
                        message: "--feedback takes comma-separated issue numbers, e.g. 12,34")
                }
                flags.feedbackNumbers.append(contentsOf: numbers)

            case "--has-task":       hasTaskSeen = true; flags.hasTask = true
            case "--no-task":        noTaskSeen = true;  flags.hasTask = false
            case "--unread":         flags.unread = true
            case "--include-emails": flags.includeEmails = true
            case "--raw":            flags.raw = true
            case "--refresh":        flags.refresh = true
            case "--json":           flags.json = true
            case "--text":           flags.json = false
            case "--yes":            flags.yes = true
            case "--token-stdin":    flags.tokenStdin = true
            case "--create-repo":    flags.createRepo = true
            case "--public":         flags.publicRepo = true
            case "--password-stdin": flags.passwordStdin = true
            case "--skip-test":      flags.skipTest = true
            case "--remove":         flags.remove = true
            case "--no-version":     flags.noVersion = true
            case "--resend":         flags.resend = true
            case "--no-email":       flags.noEmail = true
            case "--all":            flags.all = true
            case "--accept":         flags.accept = true
            case "--dismiss":        flags.dismiss = true
            case "--delete":         flags.delete = true

            default:
                throw CLIUsageError(code: "unknown_flag", message: "unknown flag '\(arg)'",
                                    hint: "run `\(CLIBranding.commandName) help` for the full list")
            }
            index += 1
        }

        if hasTaskSeen && noTaskSeen {
            throw CLIUsageError(code: "conflicting_flags",
                                message: "--has-task and --no-task are mutually exclusive")
        }
        if let low = flags.minRating, let high = flags.maxRating, low > high {
            throw CLIUsageError(code: "bad_value", message: "--min-rating cannot exceed --max-rating")
        }
        if flags.tokenStdin && flags.passwordStdin {
            throw CLIUsageError(code: "conflicting_flags",
                                message: "--token-stdin and --password-stdin both read stdin; use one per call")
        }
        return flags
    }
}
#endif

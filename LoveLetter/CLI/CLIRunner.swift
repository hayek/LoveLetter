#if os(macOS)
import Foundation

enum CLIRunner {
    static let watchdogSeconds: TimeInterval = 60

    /// The watchdog must outlast the command's own `--timeout`, or a slow but healthy write
    /// (a release emailing fifty people) would be killed while the app is still answering.
    static func watchdogSeconds(for invocation: Result<CLICommand, CLIUsageError>) -> TimeInterval {
        guard case .success(let command) = invocation, let flags = command.flags else { return watchdogSeconds }
        return max(watchdogSeconds, flags.timeout + 15)
    }

    /// Entry point from the dispatcher. Never returns.
    static func run(invocation: Result<CLICommand, CLIUsageError>) -> Never {
        // A wedged async path must never hang an agent indefinitely. It exits through the same
        // emitter as every other failure: stdout has to parse as JSON on every path, and this
        // is the one where a write's outcome is genuinely unknown.
        let limit = watchdogSeconds(for: invocation)
        let watchdog = Thread {
            Thread.sleep(forTimeInterval: limit)
            exit(emit(error: .remote(
                message: "\(CLIBranding.commandName) gave up after \(Int(limit))s.",
                hint: "If this was a write, its outcome is unknown — check Love Letter before "
                    + "retrying, or the change may be applied twice."),
                code: "timeout", exitCode: .watchdog))
        }
        // Big enough for the JSON emitter; the default 512K is what a Thread would get anyway.
        watchdog.stackSize = 1 << 19
        watchdog.start()

        Task {
            let code: Int32
            switch invocation {
            case .failure(let usage): code = emit(error: .usage(usage))
            case .success(let command): code = await execute(command)
            }
            exit(code)
        }
        // RunLoop, not dispatchMain(): distributed-notification replies arrive on a CFRunLoop
        // source, and dispatchMain() parks the thread without ever running the run loop.
        RunLoop.main.run()
        fatalError("unreachable")
    }

    static func execute(_ command: CLICommand) async -> Int32 {
        switch command {
        case .version:
            let info = CLIBranding.appBundle.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "?"
            let build = info?["CFBundleVersion"] as? String ?? "?"
            print("\(CLIBranding.commandName) \(version) (\(build))")
            return CLIExitCode.success.rawValue

        case .help(let topic):
            print(helpText(for: topic))
            return CLIExitCode.success.rawValue

        case .products(.list(let flags)):
            return await withStore(flags) { store, refreshTimedOut in
                let summaries = ProductResolver.all(cloud: store.cloud, local: store.local)
                let envelope = CLIEnvelope(asOf: summaries.compactMap(\.lastFetchedAt).max(),
                                           stale: false,
                                           refreshTimedOut: refreshTimedOut ? true : nil,
                                           items: summaries)
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(products: summaries)
            }

        case .accounts(let flags):
            return await withStore(flags) { store, _ in
                let accounts = AccountsQuery.run(cloud: store.cloud)
                let envelope = CLIEnvelope(items: [accounts])
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(accounts: accounts)
            }

        case .feedback(.list(let flags)):
            return await withStore(flags) { store, refreshTimedOut in
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
                let result = FeedbackQuery.run(flags: flags, config: config,
                                               local: store.local, cloud: store.cloud, index: index)
                let asOf = ProductResolver.lastFetchedAt(local: store.local,
                                                         owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(
                    asOf: asOf, stale: isStale(asOf),
                    refreshTimedOut: refreshTimedOut ? true : nil,
                    closedDataIncomplete: flags.state == .open ? nil : true,
                    product: ProductResolver.ref(config), filters: describe(feedback: flags),
                    page: PageInfo(limit: flags.limit, offset: flags.offset, total: result.total,
                                   hasMore: flags.offset + result.items.count < result.total),
                    items: result.items)
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(feedback: result.items)
            }

        case .feedback(.show(let number, let flags)):
            return await withStore(flags) { store, refreshTimedOut in
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
                let detail = try FeedbackQuery.detail(number: number, flags: flags, config: config,
                                                      local: store.local, cloud: store.cloud, index: index)
                let asOf = ProductResolver.lastFetchedAt(local: store.local,
                                                         owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(asOf: asOf, stale: isStale(asOf),
                                           refreshTimedOut: refreshTimedOut ? true : nil,
                                           product: ProductResolver.ref(config), items: [detail])
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(detail: detail)
            }

        case .tasks(.list(let flags)):
            return await withStore(flags) { store, refreshTimedOut in
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
                let all = index.filter(flags).map { TaskIndex.dto($0, config: config) }
                let page = Array(all.dropFirst(flags.offset).prefix(flags.limit))
                let asOf = ProductResolver.lastFetchedAt(local: store.local,
                                                         owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(
                    asOf: asOf, stale: isStale(asOf),
                    refreshTimedOut: refreshTimedOut ? true : nil,
                    closedDataIncomplete: flags.state == .open ? nil : true,
                    product: ProductResolver.ref(config), filters: describe(tasks: flags),
                    page: PageInfo(limit: flags.limit, offset: flags.offset, total: all.count,
                                   hasMore: flags.offset + page.count < all.count),
                    items: page)
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(tasks: page)
            }

        case .tasks(.show(let number, let flags)):
            return await withStore(flags) { store, refreshTimedOut in
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
                let detail = try index.detail(number: number, config: config, local: store.local)
                let asOf = ProductResolver.lastFetchedAt(local: store.local,
                                                         owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(asOf: asOf, stale: isStale(asOf),
                                           refreshTimedOut: refreshTimedOut ? true : nil,
                                           product: ProductResolver.ref(config), items: [detail])
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(taskDetail: detail)
            }

        case .versions(.list(let flags)):
            return await withStore(flags) { store, refreshTimedOut in
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let tasks = VersionQuery.issues(config: config, local: store.local).tasks
                let items = VersionQuery.versions(config: config, cloud: store.cloud)
                    .map { VersionQuery.item($0, tasks: tasks) }
                let asOf = ProductResolver.lastFetchedAt(local: store.local,
                                                         owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(asOf: asOf, stale: isStale(asOf),
                                           refreshTimedOut: refreshTimedOut ? true : nil,
                                           product: ProductResolver.ref(config), items: items)
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(versions: items)
            }

        case .versions(.show(let flags)):
            return await withVersion(flags) { detail, envelope in
                flags.json ? CLIOutput.encode(envelope([detail])) : CLIText.render(versionDetail: detail)
            }

        case .versions(.recipients(let flags)):
            return await withVersion(flags) { detail, envelope in
                flags.json ? CLIOutput.encode(envelope(detail.recipients))
                           : CLIText.render(recipients: detail.recipients)
            }

        case .templates(.list(let flags)):
            return await withStore(flags) { store, _ in
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let items = TemplateQuery.templates(config: config, cloud: store.cloud).map(TemplateQuery.dto)
                let envelope = CLIEnvelope(product: ProductResolver.ref(config), items: items)
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(templates: items)
            }

        default:
            return await executeWrite(command)
        }
    }

    // MARK: - Writes

    /// Reads whatever the write needs from this process — a secret on stdin, a key file
    /// relative to the caller's shell — then hands it to the app.
    private static func executeWrite(_ command: CLICommand) async -> Int32 {
        guard let flags = command.flags else { return CLIExitCode.usage.rawValue }
        var secret: String?
        var pem: String?
        if flags.tokenStdin || (flags.passwordStdin && !flags.remove) {
            let flag = flags.tokenStdin ? "--token-stdin" : "--password-stdin"
            guard let read = readSecret(prompt: flags.tokenStdin ? "GitHub token: " : "Password: ") else {
                return emit(error: .usage(CLIUsageError(
                    code: "missing_value", message: "\(flag) read nothing from stdin",
                    hint: "Pipe the secret in; never pass it as an argument.")))
            }
            secret = read
        }
        if case .products(.appStore) = command {
            let path = NSString(string: flags.p8Path ?? "").expandingTildeInPath
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  text.contains("PRIVATE KEY") else {
                return emit(error: .usage(CLIUsageError(
                    code: "bad_value", message: "--p8: could not read a private key from \(path)",
                    hint: "Pass the AuthKey_XXXXXXXXXX.p8 file downloaded from App Store Connect.")))
            }
            pem = text
        }
        guard let (kind, payload) = request(for: command, secret: secret, pem: pem) else {
            return emit(error: .remote(message: "\(CLIBranding.commandName) has no handler for this command."))
        }
        return await sendWrite(kind: kind, flags: flags, payload: payload)
    }

    /// The request a write command sends to the app. Pure, so tests pin the wire format;
    /// `secret` (stdin) and `pem` (the .p8's contents) are read by the caller. Empty values
    /// are dropped before sending, so a flag whose empty value is meaningful ("clear the
    /// notes") also sends a `set…` marker. nil for read commands.
    static func request(for command: CLICommand, secret: String? = nil,
                        pem: String? = nil) -> (CLIRequestKind, [String: String])? {
        func onOff(_ value: Bool?) -> String { value.map { $0 ? "on" : "off" } ?? "" }
        func numbers(_ flags: CLIFlags) -> String { flags.feedbackNumbers.map(String.init).joined(separator: ",") }

        switch command {
        case .products(.add(let f)):
            return (.addProduct, ["repo": f.repo ?? "", "name": f.name ?? "", "color": f.colorHex ?? "",
                                  "account": f.account ?? "", "redact": onOff(f.redactEmails),
                                  "token": secret ?? ""])
        case .products(.update(let f)):
            // "" is a real color (back to the default), so it travels as "none".
            return (.updateProduct, ["product": f.product, "name": f.name ?? "",
                                     "color": f.colorHex.map { $0.isEmpty ? "none" : $0 } ?? "",
                                     "mirror": onOff(f.mirrorEmails), "redact": onOff(f.redactEmails),
                                     "account": f.account ?? "", "token": secret ?? ""])
        case .products(.remove(let f)):
            return (.removeProduct, ["product": f.product])
        case .products(.appStore(let f)):
            return (.configureAppStore, ["product": f.product, "issuerID": f.issuerID ?? "",
                                         "keyID": f.keyID ?? "", "pem": pem ?? "", "appID": f.appID ?? ""])
        case .products(.email(let f)) where f.remove:
            return (.removeEmail, ["product": f.product])
        case .products(.email(let f)):
            return (.configureEmail, ["product": f.product, "preset": f.preset?.rawValue ?? "",
                                      "address": f.address ?? "", "password": secret ?? "",
                                      "senderName": f.senderName ?? "",
                                      "imapHost": f.imapHost ?? "", "imapPort": f.imapPort.map(String.init) ?? "",
                                      "smtpHost": f.smtpHost ?? "", "smtpPort": f.smtpPort.map(String.init) ?? "",
                                      "skipTest": f.skipTest ? "1" : ""])

        case .feedback(.markRead(let f)):
            return (.markRead, ["product": f.product, "feedback": numbers(f), "all": f.all ? "1" : ""])
        case .feedback(.triage(let f)):
            return (.triage, ["product": f.product, "feedback": numbers(f),
                              "action": f.accept ? "accept" : "dismiss"])

        case .tasks(.create(let f)):
            return (.createTask, ["product": f.product, "title": f.title ?? "", "notes": f.notes ?? "",
                                  "status": (f.statuses.first ?? .todo).rawValue,
                                  "priority": (f.priorities.first ?? .med).rawValue,
                                  "version": f.version ?? "", "feedback": numbers(f)])
        case .tasks(.update(let f)):
            return (.updateTask, ["product": f.product, "task": f.taskNumber.map(String.init) ?? "",
                                  "title": f.title ?? "", "notes": f.notes ?? "",
                                  "setNotes": f.notes != nil ? "1" : "",
                                  "status": f.statuses.first?.rawValue ?? "",
                                  "priority": f.priorities.first?.rawValue ?? "",
                                  "version": f.version ?? "", "noVersion": f.noVersion ? "1" : ""])
        case .tasks(.delete(let f)):
            return (.deleteTask, ["product": f.product, "task": f.taskNumber.map(String.init) ?? ""])
        case .tasks(.link(let f)):
            return (.linkTask, linkPayload(f))
        case .tasks(.unlink(let f)):
            return (.unlinkTask, linkPayload(f))

        case .versions(.create(let f)):
            return (.createVersion, ["product": f.product, "version": f.version ?? "",
                                     "title": f.title ?? "", "changelog": f.changelog ?? ""])
        case .versions(.update(let f)):
            return (.updateVersion, ["product": f.product, "version": f.version ?? "", "name": f.name ?? "",
                                     "title": f.title ?? "", "setTitle": f.title != nil ? "1" : "",
                                     "changelog": f.changelog ?? "",
                                     "setChangelog": f.changelog != nil ? "1" : ""])
        case .versions(.delete(let f)):
            return (.deleteVersion, ["product": f.product, "version": f.version ?? ""])
        case .versions(.release(let f)):
            // Newline-separated: an address can't contain one.
            return (.releaseVersion, ["product": f.product, "version": f.version ?? "",
                                      "noEmail": f.noEmail ? "1" : "", "resend": f.resend ? "1" : "",
                                      "recipients": f.recipients.joined(separator: "\n"),
                                      "skip": f.skipRecipients.joined(separator: "\n"),
                                      "subject": f.subject ?? "", "body": f.body ?? ""])

        case .templates(.create(let f)):
            return (.createTemplate, ["product": f.product, "title": f.title ?? "", "body": f.body ?? ""])
        case .templates(.update(let f)):
            return (.updateTemplate, ["product": f.product, "template": f.template ?? "",
                                      "title": f.title ?? "", "body": f.body ?? ""])
        case .templates(.delete(let f)):
            return (.deleteTemplate, ["product": f.product, "template": f.template ?? ""])

        case .respond(let f) where f.delete:
            return (.deleteAppStoreResponse, ["product": f.product, "feedback": numbers(f)])
        case .respond(let f):
            return (.respond, ["product": f.product, "feedback": numbers(f), "body": f.body ?? "",
                               "template": f.template ?? "", "via": f.channel.rawValue])

        default:
            return nil
        }
    }

    private static func linkPayload(_ flags: CLIFlags) -> [String: String] {
        ["product": flags.product,
         "task": flags.taskNumber.map(String.init) ?? "",
         "feedback": flags.feedbackNumbers.map(String.init).joined(separator: ",")]
    }

    /// Reads a secret from stdin: all of it when piped (surrounding whitespace dropped), or one
    /// no-echo line when stdin is a terminal. nil when nothing was supplied.
    static func readSecret(prompt: String) -> String? {
        let raw: String?
        if isatty(STDIN_FILENO) != 0 {
            var buffer = [CChar](repeating: 0, count: 4096)
            raw = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY).map { String(cString: $0) }
        } else {
            raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Delegates a write to the running app and prints its result. The app runs the identical
    /// call its own UI makes, so behaviour cannot drift between the two.
    static func sendWrite(kind: CLIRequestKind, flags: CLIFlags,
                          payload: [String: String]) async -> Int32 {
        do {
            let response = try await CLIRequestClient.send(
                CLIRequest(kind: kind, payload: payload.filter { !$0.value.isEmpty }),
                timeout: flags.timeout)
            guard response.ok else { return emit(error: mapRemote(response)) }
            print(render(write: response, json: flags.json))
            return CLIExitCode.success.rawValue
        } catch let error as CLIError {
            return emit(error: error)
        } catch {
            return emit(error: .remote(message: error.localizedDescription))
        }
    }

    /// `{"ok": true, "result": …, "warnings": […]}`, or with `--text` the result's fields one per line.
    static func render(write response: CLIResponse, json: Bool) -> String {
        let result = response.json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        guard json else { return CLIText.render(writeResult: result, warnings: response.warnings) }
        var envelope: [String: Any] = ["ok": true]
        if let result { envelope["result"] = result }
        if !response.warnings.isEmpty { envelope["warnings"] = response.warnings }
        guard let data = try? JSONSerialization.data(withJSONObject: envelope,
                                                     options: [.prettyPrinted, .sortedKeys,
                                                               .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return #"{"ok":true}"# }
        return text
    }

    /// Maps the app's typed failure back onto a CLI error. The app sends the exit code it
    /// actually hit, so this reconstructs the matching case rather than guessing from the
    /// error-code string — a new error code on the app side then needs no change here.
    static func mapRemote(_ response: CLIResponse) -> CLIError {
        let message = response.errorMessage ?? "The app reported a failure."
        let code = response.errorCode ?? "remote_failure"
        switch response.errorExitCode.flatMap(CLIExitCode.init(rawValue:)) {
        case .usage:
            return .usage(CLIUsageError(code: code, message: message, hint: response.errorHint))
        case .notFound:
            return .notFound(code: code, message: message, hint: response.errorHint,
                             candidates: response.errorCandidates ?? [])
        case .noLocalData:
            return .noLocalData(message: message, hint: response.errorHint)
        case .auth:
            return .auth(message: message, hint: response.errorHint)
        case .appNotRunning:
            return .appNotRunning
        default:
            return .remote(message: message, hint: response.errorHint)
        }
    }

    // MARK: - Shared plumbing

    /// Opens the store, runs `body`, prints what it returns. Every read command shares this so
    /// error mapping and exit codes stay in one place.
    ///
    /// With `--refresh`, the app is asked to poll GitHub FIRST and the store is opened only
    /// once it has answered — opening earlier would read pre-refresh data under a fresh
    /// `asOf`, which is worse than not refreshing at all. `refreshTimedOut` is passed to
    /// `body` so the envelope can say the data is stale rather than failing the read.
    static func withStore(_ flags: CLIFlags,
                          _ body: (CLIStore, Bool) throws -> String) async -> Int32 {
        do {
            var timedOut = false
            if flags.refresh {
                // Resolving the product needs the store, so open a short-lived one first.
                let productID = try? ProductResolver.resolve(flags.product,
                                                             cloud: CLIStore.open().cloud).id
                timedOut = try await requestRefresh(productID: productID, timeout: flags.timeout)
            }
            let store = try CLIStore.open()
            print(try body(store, timedOut))
            return CLIExitCode.success.rawValue
        } catch let error as CLIError {
            return emit(error: error)
        } catch {
            return emit(error: .noLocalData(message: error.localizedDescription, hint: nil))
        }
    }

    /// `versions show` / `versions recipients`: resolves the product and version, then lets
    /// `body` pick what to print. `envelope` wraps items with the usual freshness fields.
    private static func withVersion<Item: Codable>(
        _ flags: CLIFlags,
        _ body: (VersionDetailDTO, ([Item]) -> CLIEnvelope<Item>) -> String
    ) async -> Int32 {
        await withStore(flags) { store, refreshTimedOut in
            let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
            let version = try VersionQuery.find(flags.version ?? "",
                                                in: VersionQuery.versions(config: config, cloud: store.cloud),
                                                config: config)
            let detail = VersionQuery.detail(version, config: config, local: store.local,
                                             cloud: store.cloud, includeEmails: flags.includeEmails)
            let asOf = ProductResolver.lastFetchedAt(local: store.local, owner: config.owner, repo: config.repo)
            return body(detail) { items in
                CLIEnvelope(asOf: asOf, stale: isStale(asOf),
                            refreshTimedOut: refreshTimedOut ? true : nil,
                            product: ProductResolver.ref(config), items: items)
            }
        }
    }

    /// Returns true when the refresh timed out (answer from cache and say so). Only
    /// app-not-running is fatal.
    static func requestRefresh(productID: UUID?, timeout: TimeInterval) async throws -> Bool {
        var payload: [String: String] = [:]
        if let productID { payload["productID"] = productID.uuidString }
        do {
            _ = try await CLIRequestClient.send(CLIRequest(kind: .refresh, payload: payload),
                                                timeout: timeout)
            return false
        } catch CLIError.appNotRunning {
            throw CLIError.appNotRunning
        } catch {
            return true
        }
    }

    /// The app polls every 15 minutes; anything older than that is stale.
    static func isStale(_ asOf: Date?, now: Date = Date()) -> Bool {
        guard let asOf else { return true }
        return now.timeIntervalSince(asOf) > 15 * 60
    }

    /// Echoes the filters that were actually applied, so an agent can self-check a guessed
    /// value. Only keys the executed command really honours may appear: a shared echo listed
    /// flags the other noun ignores, so `tasks --since 7d` looked filtered while returning
    /// every task in the repo. Keep each list in step with the query that consumes the flags
    /// (`FeedbackQuery.matches` / `TaskIndex.filter`).
    static func describe(feedback flags: CLIFlags) -> [String: String] {
        var described: [String: String] = ["state": flags.state.rawValue,
                                           "sort": flags.sort.rawValue,
                                           "order": flags.order.rawValue]
        if !flags.labels.isEmpty     { described["label"] = flags.labels.joined(separator: ",") }
        if !flags.sources.isEmpty    { described["source"] = flags.sources.map(\.rawValue).joined(separator: ",") }
        if let search = flags.search { described["search"] = search }
        if let since = flags.since   { described["since"] = CLIOutput.iso8601.string(from: since) }
        if let since = flags.updatedSince { described["updatedSince"] = CLIOutput.iso8601.string(from: since) }
        if let low = flags.minRating  { described["minRating"] = String(low) }
        if let high = flags.maxRating { described["maxRating"] = String(high) }
        if let version = flags.appVersion { described["appVersion"] = version }
        if let hasTask = flags.hasTask    { described["hasTask"] = String(hasTask) }
        if let unread = flags.unread      { described["unread"] = String(unread) }
        return described
    }

    /// Tasks are always newest-number-first, so `--sort`/`--order` are not echoed either.
    static func describe(tasks flags: CLIFlags) -> [String: String] {
        var described: [String: String] = ["state": flags.state.rawValue]
        if !flags.statuses.isEmpty   { described["status"] = flags.statuses.map(\.rawValue).joined(separator: ",") }
        if !flags.priorities.isEmpty { described["priority"] = flags.priorities.map(\.rawValue).joined(separator: ",") }
        if let version = flags.version { described["version"] = version }
        if let search = flags.search   { described["search"] = search }
        return described
    }

    /// JSON error on stdout (so a failed call is still parseable) plus a one-liner on stderr.
    /// `code`/`exitCode` override the error's own, for failures the `CLIError` cases don't
    /// model — currently only the watchdog, which reports `timeout`/7 through a `.remote`.
    static func emit(error: CLIError, code: String? = nil, exitCode: CLIExitCode? = nil) -> Int32 {
        var payload: [String: Any] = ["code": code ?? error.code, "message": error.message]
        if let hint = error.hint { payload["hint"] = hint }
        if !error.candidates.isEmpty { payload["candidates"] = error.candidates }
        if let data = try? JSONSerialization.data(withJSONObject: ["error": payload],
                                                  options: [.prettyPrinted, .sortedKeys,
                                                            .withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        FileHandle.standardError.write(Data("\(CLIBranding.commandName): \(error.message)\n".utf8))
        return (exitCode ?? error.exitCode).rawValue
    }

    // MARK: - Help

    static func helpText(for topic: String?) -> String {
        let name = CLIBranding.commandName
        switch topic {
        case "feedback":
            return """
            \(name) feedback [list] --product <p> [filters]
            \(name) feedback show <number> --product <p> [--raw]
            \(name) feedback mark-read --product <p> (--feedback 12,34 | --all)
            \(name) feedback triage --product <p> --feedback <n> (--accept | --dismiss)

            Filters:
              --state open|closed|all      default: open
              --source sdk|app-store|email
              --label <name>        repeatable; ORs together (exact match)
              --search <text>       title and description
              --since 7d|YYYY-MM-DD --updated-since ...
              --min-rating N --max-rating N     inclusive, 1-5
              --app-version <v>
              --has-task | --no-task
              --unread              only items not yet opened in Love Letter
              --include-emails      unredacted reporter addresses
              --sort created|updated  --order desc|asc
              --limit N (<=200, default 20)  --offset N
              --refresh             ask the running app to poll GitHub first
              --text                human table (JSON is the default)

            mark-read clears the unread dot, as opening the item in the app does.
            triage acts on the app's AI suggestion for one item (see its `triage` field):
            --accept links it to the suggested task or creates the suggested one;
            --dismiss drops the suggestion. Both need Love Letter running.
            """
        case "tasks":
            return """
            \(name) tasks [list] --product <p> [--status ...] [--priority ...] [--version <v>] [--search <t>]
            \(name) tasks show <number> --product <p>
            \(name) tasks create --product <p> --title <t> [--notes <n>] [--status todo|in-progress|done]
                                 [--priority low|med|high] [--version <v>] [--feedback 12,34]
            \(name) tasks update --product <p> --task <n> [--title <t>] [--notes <n>] [--status <s>]
                                 [--priority <p>] [--version <v> | --no-version]
            \(name) tasks delete --product <p> --task <n> --yes
            \(name) tasks link   --product <p> --task <n> --feedback 12,34
            \(name) tasks unlink --product <p> --task <n> --feedback 12

            update changes only the fields you pass (status done closes the issue; any
            other status reopens it). --version moves the task to that version's
            milestone; --no-version clears it. delete permanently deletes the GitHub
            issue. Every write goes to GitHub and needs Love Letter running.
            """
        case "respond":
            return """
            \(name) respond --product <p> --feedback <n> --body <text>
                            [--template <title>] [--via auto|email|app-store|comment]
            \(name) respond --product <p> --feedback <n> --delete --yes

            Sends immediately. Show the drafted reply to the user and get explicit
            agreement first. --via auto emails the reporter, or posts an App Store
            developer response for a review (re-running replaces that response).
            --delete removes the App Store developer response. Needs Love Letter running.
            """
        case "products":
            return """
            \(name) products [list] [--refresh] [--text]
            \(name) products add --repo <owner/repo> [--name <n>] [--color <c>]
                                 [--token-stdin | --account <login>] [--redact-emails on|off]
            \(name) products update --product <p> [--name <n>] [--color <c>] [--mirror-emails on|off]
                                    [--redact-emails on|off] [--token-stdin | --account <login>]
            \(name) products remove --product <p> --yes
            \(name) products app-store --product <p> --issuer-id <id> --key-id <id> --p8 <path>
                                       [--app-id <numeric id>]
            \(name) products email --product <p> --preset gmail|icloud|outlook|custom
                                   --address <addr> --password-stdin [--sender-name <n>]
                                   [--imap-host <h> --imap-port <n> --smtp-host <h> --smtp-port <n>]
                                   [--skip-test]
            \(name) products email --product <p> --remove --yes

            list shows each product's feedback repo, connected code repo, versions,
            sources, counts and last-fetch time.

            add: the GitHub token is never an argument. Pipe it with --token-stdin, or
            name a GitHub account connected in Love Letter with --account. With neither,
            the app uses whichever connected account can see the repository. The token
            needs read and write access to the repository's issues. Sender addresses in
            mirrored comments are redacted unless the repository is private.

            --color: none, a 6-digit hex, or mint, periwinkle, rose, apricot, lavender,
            emerald, coral, sky, amber, orchid, cyan, tangerine.

            app-store verifies the key and lists its apps; --app-id picks one when the
            key sees several. email tests the IMAP login before saving (--skip-test to
            save regardless). All of these need Love Letter running.
            """
        case "versions":
            return """
            \(name) versions [list] --product <p>
            \(name) versions show --product <p> --version <name> [--include-emails]
            \(name) versions recipients --product <p> --version <name> [--include-emails]
            \(name) versions create --product <p> --version <name> [--title <t>] [--changelog <text>]
            \(name) versions update --product <p> --version <name> [--name <new name>]
                                    [--title <t>] [--changelog <text>]
            \(name) versions delete --product <p> --version <name> --yes
            \(name) versions release --product <p> --version <name> --yes
                                     [--no-email] [--recipient <email>]... [--skip <email>]...
                                     [--resend] [--subject <s>] [--body <text>]

            A version is a GitHub milestone; assign tasks with `tasks update --version`.
            recipients are the reporters of feedback linked to the version's done tasks.
            release emails them (threaded into their feedback conversation), closes
            the milestone and publishes a GitHub release tagged v<name>. Reporters
            already emailed are skipped unless --resend (or named with --recipient).
            --subject/--body override the default message; placeholders: {appName}
            {version} {whatsNew} {theirFeedbacks}. --no-email releases without emailing
            anyone. With no mail account set up in Love Letter, a release only closes the
            milestone, as the app's "Mark released (no email)" does.
            create rolls the version back if its milestone can't be created, so it can
            simply be re-run. Writes need Love Letter running.
            """
        case "templates":
            return """
            \(name) templates [list] --product <p>
            \(name) templates create --product <p> --title <t> --body <text>
            \(name) templates update --product <p> --template <title> [--title <t>] [--body <text>]
            \(name) templates delete --product <p> --template <title> --yes

            Saved reply templates, used with `respond --template <title>`.
            """
        case "accounts":
            return """
            \(name) accounts [--text]

            The GitHub accounts and mail accounts connected in Love Letter. Use a GitHub
            login with `products add --account`.
            """
        default:
            return """
            \(name) — read and act on app feedback

            Commands:
              products [list|add|update|remove|app-store|email]   products and their sources
              feedback [list|show|mark-read|triage]                read and triage feedback
              tasks [list|show|create|update|delete|link|unlink]   read and write tasks
              versions [list|show|recipients|create|update|delete|release]   versions and releases
              templates [list|create|update|delete]                saved reply templates
              respond                     reply to a feedback item
              accounts                    connected GitHub and mail accounts
              help [<command>]            detailed help (or: <command> --help)
              version

            Output is JSON on stdout by default; --text renders a human table.
            Start with `\(name) products` — most commands need --product.
            Writes need Love Letter running; destructive or outward-facing ones need --yes.
            """
        }
    }
}
#endif

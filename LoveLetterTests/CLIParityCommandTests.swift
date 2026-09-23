import XCTest
@testable import LoveLetter

#if os(macOS)
/// Grammar, wire format and output of the commands that bring the CLI to parity with the app:
/// products add/update/remove/app-store/email, versions, templates, tasks update/delete,
/// feedback mark-read/triage, respond --delete and accounts.
final class CLIParityCommandTests: XCTestCase {

    private func parse(_ args: String...) -> Result<CLICommand, CLIUsageError>? {
        CLIInvocation.parse(["/path/to/LoveLetter"] + args)
    }

    private func failure(_ args: String..., file: StaticString = #filePath, line: UInt = #line) -> CLIUsageError? {
        guard case .failure(let error)? = CLIInvocation.parse(["/path/to/LoveLetter"] + args) else {
            XCTFail("expected a usage error for \(args)", file: file, line: line)
            return nil
        }
        return error
    }

    private func request(_ args: String..., secret: String? = nil,
                         pem: String? = nil) -> (CLIRequestKind, [String: String])? {
        guard case .success(let command)? = CLIInvocation.parse(["/path/to/LoveLetter"] + args) else { return nil }
        return CLIRunner.request(for: command, secret: secret, pem: pem)
    }

    // MARK: - Nouns and help

    func testNewNounsAreCLI() {
        XCTAssertNotNil(parse("versions", "--product", "P"))
        XCTAssertNotNil(parse("templates", "--product", "P"))
        XCTAssertNotNil(parse("accounts"))
    }

    func testNounHelpFlagIsHelpForThatNoun() {
        guard case .success(.help("versions"))? = parse("versions", "release", "--help") else {
            return XCTFail("expected help for versions")
        }
        guard case .success(.help("products"))? = parse("products", "-h") else {
            return XCTFail("expected help for products")
        }
    }

    func testEveryNounHasItsOwnHelp() {
        let general = CLIRunner.helpText(for: nil)
        for noun in ["products", "feedback", "tasks", "versions", "templates", "respond", "accounts"] {
            let text = CLIRunner.helpText(for: noun)
            XCTAssertNotEqual(text, general, "\(noun) has no help of its own")
            XCTAssertTrue(text.contains("\(CLIBranding.commandName) \(noun)"), noun)
        }
    }

    // MARK: - products add

    func testProductsAddParsesRepoNameAndColor() {
        guard case .success(.products(.add(let flags)))? =
                parse("products", "add", "--repo", "hayek/app-feedback", "--name", "My App",
                      "--color", "Rose", "--token-stdin")
        else { return XCTFail("expected products add") }
        XCTAssertEqual(flags.repo, "hayek/app-feedback")
        XCTAssertEqual(flags.name, "My App")
        XCTAssertEqual(flags.colorHex, "ff6b8a", "palette names resolve to their stored hex")
        XCTAssertTrue(flags.tokenStdin)
    }

    func testProductsAddDoesNotNeedAProduct() {
        guard case .success(.products(.add))? = parse("products", "add", "--repo", "o/r") else {
            return XCTFail("add creates the product, so --product can't be required")
        }
    }

    func testProductsAddRequiresAWellFormedRepo() {
        XCTAssertEqual(failure("products", "add")?.code, "missing_flag")
        XCTAssertEqual(failure("products", "add", "--repo", "just-a-name")?.code, "bad_value")
        XCTAssertEqual(failure("products", "add", "--repo", "a/b/c")?.code, "bad_value")
    }

    func testRepoAcceptsAPastedGitHubURL() {
        XCTAssertEqual(CLIInvocation.parseRepo("https://github.com/o/r.git")?.owner, "o")
        XCTAssertEqual(CLIInvocation.parseRepo("https://github.com/o/r.git")?.repo, "r")
        XCTAssertEqual(CLIInvocation.parseRepo("git@github.com:o/r")?.repo, "r")
        XCTAssertNil(CLIInvocation.parseRepo("o/"))
    }

    func testTokenStdinAndAccountAreMutuallyExclusive() {
        XCTAssertEqual(failure("products", "add", "--repo", "o/r", "--token-stdin", "--account", "me")?.code,
                       "conflicting_flags")
    }

    func testColorAcceptsHexAndNone() {
        XCTAssertEqual(CLIInvocation.parseColor("#4EF8D0"), "4ef8d0")
        XCTAssertEqual(CLIInvocation.parseColor("none"), "")
        XCTAssertNil(CLIInvocation.parseColor("chartreuse"))
        XCTAssertEqual(failure("products", "add", "--repo", "o/r", "--color", "chartreuse")?.code, "bad_value")
    }

    /// The token must never travel as an argument, so the wire payload carries only what the
    /// caller read from stdin.
    func testProductsAddSendsTheStdinTokenNotAnArgument() throws {
        let (kind, payload) = try XCTUnwrap(request("products", "add", "--repo", "o/r", "--token-stdin",
                                                    secret: "ghp_secret"))
        XCTAssertEqual(kind, .addProduct)
        XCTAssertEqual(payload["token"], "ghp_secret")
        XCTAssertEqual(payload["repo"], "o/r")
    }

    // MARK: - products update / remove

    func testProductsUpdateNeedsSomethingToChange() {
        XCTAssertEqual(failure("products", "update", "--product", "P")?.code, "missing_flag")
    }

    func testProductsUpdateSendsResetColorAsNone() throws {
        let (kind, payload) = try XCTUnwrap(request("products", "update", "--product", "P", "--color", "none",
                                                    "--mirror-emails", "off"))
        XCTAssertEqual(kind, .updateProduct)
        XCTAssertEqual(payload["color"], "none", "an empty value would be dropped before sending")
        XCTAssertEqual(payload["mirror"], "off")
        XCTAssertEqual(payload["redact"], "", "an untouched toggle must not be sent")
    }

    func testOnOffFlagsRejectOtherValues() {
        XCTAssertEqual(failure("products", "update", "--product", "P", "--mirror-emails", "yes")?.code, "bad_value")
    }

    func testProductsRemoveRequiresConfirmation() {
        let error = failure("products", "remove", "--product", "P")
        XCTAssertEqual(error?.code, "confirmation_required")
        XCTAssertTrue(error?.hint?.contains("--yes") == true)
        guard case .success(.products(.remove))? = parse("products", "remove", "--product", "P", "--yes") else {
            return XCTFail("--yes should confirm")
        }
    }

    // MARK: - products app-store / email

    func testAppStoreRequiresIssuerKeyAndP8() {
        XCTAssertTrue(failure("products", "app-store", "--product", "P", "--key-id", "K", "--p8", "k.p8")?
            .message.contains("--issuer-id") == true)
        XCTAssertEqual(failure("products", "app-store", "--product", "P", "--issuer-id", "I", "--key-id", "K",
                               "--p8", "k.p8", "--app-id", "abc")?.code, "bad_value")
    }

    func testAppStoreSendsTheKeyContentsNotThePath() throws {
        let (kind, payload) = try XCTUnwrap(request("products", "app-store", "--product", "P", "--issuer-id", "I",
                                                    "--key-id", "K", "--p8", "/tmp/AuthKey.p8", "--app-id", "123",
                                                    pem: "-----BEGIN PRIVATE KEY-----"))
        XCTAssertEqual(kind, .configureAppStore)
        XCTAssertEqual(payload["pem"], "-----BEGIN PRIVATE KEY-----")
        XCTAssertNil(payload["p8"])
        XCTAssertEqual(payload["appID"], "123")
    }

    func testSlowWritesGetALongerDefaultTimeoutButAnExplicitOneWins() {
        guard case .success(.products(.appStore(let flags)))? =
                parse("products", "app-store", "--product", "P", "--issuer-id", "I", "--key-id", "K", "--p8", "k")
        else { return XCTFail() }
        XCTAssertEqual(flags.timeout, CLIInvocation.slowWriteTimeout)

        guard case .success(.versions(.release(let release)))? =
                parse("versions", "release", "--product", "P", "--version", "1.0", "--yes", "--timeout", "12")
        else { return XCTFail() }
        XCTAssertEqual(release.timeout, 12)
    }

    func testTheWatchdogOutlastsTheCommandTimeout() {
        let release = CLIInvocation.parse(["x", "versions", "release", "--product", "P", "--version", "1", "--yes"])!
        XCTAssertGreaterThan(CLIRunner.watchdogSeconds(for: release), CLIInvocation.releaseTimeout)
        let read = CLIInvocation.parse(["x", "feedback", "--product", "P"])!
        XCTAssertEqual(CLIRunner.watchdogSeconds(for: read), CLIRunner.watchdogSeconds)
    }

    func testEmailSourceRequiresPresetAddressAndStdinPassword() {
        XCTAssertTrue(failure("products", "email", "--product", "P", "--address", "a@b.c", "--password-stdin")?
            .message.contains("--preset") == true)
        XCTAssertTrue(failure("products", "email", "--product", "P", "--preset", "gmail", "--address", "a@b.c")?
            .message.contains("--password-stdin") == true)
        XCTAssertEqual(failure("products", "email", "--product", "P", "--preset", "custom", "--address", "a@b.c",
                               "--password-stdin")?.code, "missing_flag", "custom needs its hosts")
    }

    func testEmailRemoveNeedsOnlyConfirmation() throws {
        XCTAssertEqual(failure("products", "email", "--product", "P", "--remove")?.code, "confirmation_required")
        let (kind, payload) = try XCTUnwrap(request("products", "email", "--product", "P", "--remove", "--yes"))
        XCTAssertEqual(kind, .removeEmail)
        XCTAssertEqual(payload, ["product": "P"])
    }

    func testEmailSourceWirePayload() throws {
        let (kind, payload) = try XCTUnwrap(request("products", "email", "--product", "P", "--preset", "custom",
                                                    "--address", "fb@x.com", "--password-stdin",
                                                    "--imap-host", "imap.x.com", "--imap-port", "993",
                                                    "--smtp-host", "smtp.x.com", "--skip-test",
                                                    secret: "pw"))
        XCTAssertEqual(kind, .configureEmail)
        XCTAssertEqual(payload["password"], "pw")
        XCTAssertEqual(payload["preset"], "custom")
        XCTAssertEqual(payload["imapPort"], "993")
        XCTAssertEqual(payload["skipTest"], "1")
    }

    func testTwoStdinSecretsInOneCallAreRejected() {
        XCTAssertEqual(failure("products", "email", "--product", "P", "--token-stdin", "--password-stdin")?.code,
                       "conflicting_flags")
    }

    // MARK: - tasks update / delete

    func testTasksUpdateAcceptsAPositionalNumber() {
        guard case .success(.tasks(.update(let flags)))? =
                parse("tasks", "update", "42", "--product", "P", "--status", "done")
        else { return XCTFail() }
        XCTAssertEqual(flags.taskNumber, 42)
    }

    func testTasksUpdateValidation() {
        XCTAssertEqual(failure("tasks", "update", "--product", "P", "--status", "done")?.code, "missing_flag")
        XCTAssertEqual(failure("tasks", "update", "--product", "P", "--task", "4")?.code, "missing_flag")
        XCTAssertEqual(failure("tasks", "update", "--product", "P", "--task", "4", "--version", "1",
                               "--no-version")?.code, "conflicting_flags")
        XCTAssertEqual(failure("tasks", "update", "--product", "P", "--task", "4", "--status", "todo",
                               "--status", "done")?.code, "bad_value")
    }

    /// Clearing notes is a real edit, but an empty value is dropped before sending — so the
    /// request carries an explicit marker.
    func testTasksUpdateMarksAnExplicitEmptyNotes() throws {
        let (_, payload) = try XCTUnwrap(request("tasks", "update", "--product", "P", "--task", "4", "--notes", ""))
        XCTAssertEqual(payload["setNotes"], "1")
        XCTAssertEqual(payload["status"], "", "an untouched status must not be sent")
    }

    func testTasksDeleteRequiresConfirmation() {
        XCTAssertEqual(failure("tasks", "delete", "--product", "P", "--task", "4")?.code, "confirmation_required")
    }

    // MARK: - versions

    func testVersionsVerbsNeedAVersion() {
        XCTAssertTrue(failure("versions", "show", "--product", "P")?.message.contains("--version") == true)
        guard case .success(.versions(.list))? = parse("versions", "--product", "P") else {
            return XCTFail("bare versions lists")
        }
    }

    func testVersionsUpdateCarriesPresenceMarkers() throws {
        let (kind, payload) = try XCTUnwrap(request("versions", "update", "--product", "P", "--version", "1.0",
                                                    "--name", "1.0.1", "--changelog", ""))
        XCTAssertEqual(kind, .updateVersion)
        XCTAssertEqual(payload["name"], "1.0.1")
        XCTAssertEqual(payload["setChangelog"], "1")
        XCTAssertEqual(payload["setTitle"], "")
        XCTAssertEqual(failure("versions", "update", "--product", "P", "--version", "1.0")?.code, "missing_flag")
    }

    func testReleaseRequiresConfirmationAndPointsAtThePreview() {
        let error = failure("versions", "release", "--product", "P", "--version", "1.0")
        XCTAssertEqual(error?.code, "confirmation_required")
        XCTAssertTrue(error?.hint?.contains("versions recipients") == true)
    }

    func testReleaseNoEmailConflictsWithRecipientFlags() {
        XCTAssertEqual(failure("versions", "release", "--product", "P", "--version", "1.0", "--yes", "--no-email",
                               "--recipient", "a@b.c")?.code, "conflicting_flags")
    }

    func testReleaseWirePayloadSeparatesRecipientsByNewline() throws {
        let (kind, payload) = try XCTUnwrap(request("versions", "release", "--product", "P", "--version", "1.0",
                                                    "--yes", "--recipient", "a@b.c", "--recipient", "d@e.f",
                                                    "--skip", "x@y.z", "--resend"))
        XCTAssertEqual(kind, .releaseVersion)
        XCTAssertEqual(payload["recipients"], "a@b.c\nd@e.f")
        XCTAssertEqual(payload["skip"], "x@y.z")
        XCTAssertEqual(payload["resend"], "1")
    }

    // MARK: - templates

    func testTemplatesGrammar() throws {
        XCTAssertEqual(failure("templates", "create", "--product", "P", "--title", "T")?.code, "missing_flag")
        XCTAssertEqual(failure("templates", "update", "--product", "P", "--template", "T")?.code, "missing_flag")
        XCTAssertEqual(failure("templates", "delete", "--product", "P", "--template", "T")?.code,
                       "confirmation_required")
        let (kind, payload) = try XCTUnwrap(request("templates", "update", "--product", "P", "--template", "Thanks",
                                                    "--body", "New body"))
        XCTAssertEqual(kind, .updateTemplate)
        XCTAssertEqual(payload["template"], "Thanks")
    }

    // MARK: - feedback mark-read / triage, respond --delete

    func testMarkReadTakesNumbersOrAllButNotBoth() throws {
        XCTAssertEqual(failure("feedback", "mark-read", "--product", "P")?.code, "missing_flag")
        XCTAssertEqual(failure("feedback", "mark-read", "--product", "P", "--all", "--feedback", "1")?.code,
                       "conflicting_flags")
        let (kind, payload) = try XCTUnwrap(request("feedback", "mark-read", "--product", "P", "--feedback", "3,4"))
        XCTAssertEqual(kind, .markRead)
        XCTAssertEqual(payload["feedback"], "3,4")
    }

    func testTriageTakesExactlyOneAction() throws {
        XCTAssertEqual(failure("feedback", "triage", "--product", "P", "--feedback", "3")?.code, "missing_flag")
        XCTAssertEqual(failure("feedback", "triage", "--product", "P", "--feedback", "3", "--accept", "--dismiss")?
            .code, "conflicting_flags")
        let (_, payload) = try XCTUnwrap(request("feedback", "triage", "--product", "P", "--feedback", "3", "--dismiss"))
        XCTAssertEqual(payload["action"], "dismiss")
    }

    func testRespondDeleteNeedsConfirmationAndNoBody() throws {
        XCTAssertEqual(failure("respond", "--product", "P", "--feedback", "3", "--delete")?.code,
                       "confirmation_required")
        XCTAssertEqual(failure("respond", "--product", "P", "--feedback", "3", "--delete", "--yes", "--body", "x")?
            .code, "conflicting_flags")
        let (kind, _) = try XCTUnwrap(request("respond", "--product", "P", "--feedback", "3", "--delete", "--yes"))
        XCTAssertEqual(kind, .deleteAppStoreResponse)
    }

    func testUnreadFilterIsEchoed() {
        guard case .success(.feedback(.list(let flags)))? = parse("feedback", "--product", "P", "--unread") else {
            return XCTFail()
        }
        XCTAssertEqual(CLIRunner.describe(feedback: flags)["unread"], "true")
    }

    func testReadCommandsSendNoRequest() {
        guard case .success(let command)? = parse("versions", "show", "--product", "P", "--version", "1") else {
            return XCTFail()
        }
        XCTAssertNil(CLIRunner.request(for: command))
    }

    // MARK: - Output

    func testWriteResultRendersAsJSONByDefaultAndLinesWithText() throws {
        let response = CLIResponse(id: UUID(), ok: true, warnings: ["careful"],
                                   json: #"{"name":"1.2.0","taskCount":3}"#)
        let json = CLIRunner.render(write: response, json: true)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual((object["result"] as? [String: Any])?["taskCount"] as? Int, 3)
        XCTAssertEqual(object["warnings"] as? [String], ["careful"])

        let text = CLIRunner.render(write: response, json: false)
        XCTAssertTrue(text.hasPrefix("OK"))
        XCTAssertTrue(text.contains("name: 1.2.0"))
        XCTAssertTrue(text.contains("warning: careful"))
    }

    func testVersionTextShowsStateAndProgress() {
        let item = VersionItem(name: "1.2.0", releaseTitle: "Polish", state: "wip", milestoneNumber: 4,
                               released: false, releasedAt: nil, releaseTag: nil, taskCount: 4, doneCount: 1,
                               createdAt: Date())
        let text = CLIText.render(versions: [item])
        XCTAssertTrue(text.contains("1.2.0"))
        XCTAssertTrue(text.contains("wip"))
        XCTAssertTrue(text.contains("1/4 done"))
        XCTAssertEqual(CLIText.render(versions: []), "No versions.")
    }

    func testRecipientTextFlagsAlreadyEmailed() {
        let text = CLIText.render(recipients: [ReleaseRecipientDTO(email: "a***@b.com", feedback: [3, 5],
                                                                   alreadyEmailed: true)])
        XCTAssertTrue(text.contains("#3 #5"))
        XCTAssertTrue(text.contains("already emailed"))
    }

    func testFeedbackTextMarksUnreadItems() {
        var item = FeedbackItem(number: 7, title: "T", app: nil, appVersion: nil, source: "sdk", rating: nil,
                                state: "open", createdAt: Date(), updatedAt: Date(), device: nil, os: nil,
                                email: nil, description: "", truncated: false, labels: [], tasks: [],
                                triage: nil, url: "u")
        XCTAssertFalse(CLIText.render(feedback: [item]).hasPrefix("•"))
        item.unread = true
        XCTAssertTrue(CLIText.render(feedback: [item]).hasPrefix("•"))
    }

    /// An item's `unread` field is omitted, not `null`, when unknown — additive to the contract.
    func testUnreadIsOmittedWhenNil() {
        let item = FeedbackItem(number: 7, title: "T", app: nil, appVersion: nil, source: "sdk", rating: nil,
                                state: "open", createdAt: Date(), updatedAt: Date(), device: nil, os: nil,
                                email: nil, description: "", truncated: false, labels: [], tasks: [],
                                triage: nil, url: "u")
        XCTAssertFalse(CLIOutput.encode(item).contains("unread"))
    }

    /// Candidates survive the trip back from the app, so a not-found from a write still lists
    /// the valid choices (accounts, apps, versions).
    func testRemoteNotFoundKeepsItsCandidates() {
        let error = CLIRunner.mapRemote(CLIResponse(id: UUID(), ok: false, errorCode: "account_not_found",
                                                    errorMessage: "m", errorExitCode: CLIExitCode.notFound.rawValue,
                                                    errorCandidates: ["octocat"]))
        XCTAssertEqual(error.candidates, ["octocat"])
    }
}
#endif

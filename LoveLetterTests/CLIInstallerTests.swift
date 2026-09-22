import XCTest
@testable import LoveLetter

#if os(macOS)
final class CLIInstallerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appending(path: "installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBinary(named name: String = "LoveLetter") throws -> URL {
        let url = root.appending(path: name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        return url
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - CLI

    func testInstallsIntoTheFirstWritableCandidate() throws {
        let preferred = root.appending(path: "usr-local-bin")   // deliberately absent
        let fallback = try makeDirectory("dot-local-bin")

        let installed = try CLIInstaller.installCLI(candidates: [preferred, fallback],
                                                    binary: try makeBinary())
        XCTAssertEqual(installed.deletingLastPathComponent().lastPathComponent, "dot-local-bin")
        XCTAssertEqual(installed.lastPathComponent, CLIBranding.commandName)
    }

    /// A copy would lose the provisioning profile and with it keychain access.
    func testInstallCreatesASymlinkNotACopy() throws {
        let directory = try makeDirectory("bin")
        let binary = try makeBinary()
        let installed = try CLIInstaller.installCLI(candidates: [directory], binary: binary)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installed.path),
                       binary.path, "must symlink, never copy")
    }

    func testInstallIsIdempotentAndRepointsAnExistingLink() throws {
        let directory = try makeDirectory("bin")
        _ = try CLIInstaller.installCLI(candidates: [directory], binary: try makeBinary(named: "Old"))
        let installed = try CLIInstaller.installCLI(candidates: [directory],
                                                    binary: try makeBinary(named: "New"))
        XCTAssertTrue(try FileManager.default.destinationOfSymbolicLink(atPath: installed.path)
            .hasSuffix("New"))
    }

    func testStatusReportsNotInstalledInstalledAndBroken() throws {
        let directory = try makeDirectory("bin")
        guard case .notInstalled = CLIInstaller.cliStatus(searchPaths: [directory]) else {
            return XCTFail("expected .notInstalled")
        }

        let binary = try makeBinary()
        let installed = try CLIInstaller.installCLI(candidates: [directory], binary: binary)
        guard case .installed(let url) = CLIInstaller.cliStatus(searchPaths: [directory]) else {
            return XCTFail("expected .installed")
        }
        XCTAssertEqual(url, installed)

        try FileManager.default.removeItem(at: binary)      // dangling link
        guard case .brokenLink = CLIInstaller.cliStatus(searchPaths: [directory]) else {
            return XCTFail("expected .brokenLink")
        }
    }

    func testInstallFailsCleanlyWhenNoCandidateIsWritable() throws {
        XCTAssertThrowsError(try CLIInstaller.installCLI(
            candidates: [URL(filePath: "/System/definitely-not-writable")],
            binary: try makeBinary()))
    }

    func testStatusSkipsAMissingCandidateAndFindsALaterOne() throws {
        let missing = root.appending(path: "nope")
        let directory = try makeDirectory("bin")
        _ = try CLIInstaller.installCLI(candidates: [directory], binary: try makeBinary())
        guard case .installed = CLIInstaller.cliStatus(searchPaths: [missing, directory]) else {
            return XCTFail("expected .installed from the second candidate")
        }
    }

    // MARK: - Skill

    func testInstallSkillSymlinksTheBundledFolder() throws {
        let source = try makeDirectory("Skill/loveletter")
        try Data("---\nname: loveletter\n---\n".utf8).write(to: source.appending(path: "SKILL.md"))
        let destination = root.appending(path: "home/.claude/skills/loveletter")

        let installed = try CLIInstaller.installSkill(source: source, destination: destination)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installed.path),
                       source.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installed.appending(path: "SKILL.md").path),
            "the SKILL.md must be reachable through the link")
    }

    func testInstallSkillThrowsWhenTheBundledFolderIsMissing() {
        XCTAssertThrowsError(try CLIInstaller.installSkill(
            source: root.appending(path: "absent"),
            destination: root.appending(path: "dest")))
    }

    func testSkillDestinationIsTheClaudeSkillsFolder() {
        XCTAssertTrue(CLIInstaller.skillDestinationURL.path.hasSuffix(".claude/skills/loveletter"))
    }

    // MARK: - Pre-rename (appfeedback) links

    private func makeLegacyAppBinary() throws -> URL {
        let macOS = try makeDirectory("Old/AppFeedback.app/Contents/MacOS")
        let url = macOS.appending(path: "AppFeedback")
        try Data("#!/bin/sh\n".utf8).write(to: url)
        return url
    }

    func testInstallCLIReplacesAPreRenameLinkToTheOldBinary() throws {
        let directory = try makeDirectory("bin")
        let legacy = directory.appending(path: "appfeedback")
        try FileManager.default.createSymbolicLink(at: legacy,
                                                   withDestinationURL: try makeLegacyAppBinary())
        XCTAssertEqual(CLIInstaller.legacyCLILinks(in: [directory]), [legacy])

        let installed = try CLIInstaller.installCLI(candidates: [directory], binary: try makeBinary())
        XCTAssertEqual(installed.lastPathComponent, "loveletter")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: legacy.path),
                     "the old appfeedback link must be removed")
        XCTAssertTrue(CLIInstaller.legacyCLILinks(in: [directory]).isEmpty)
    }

    func testLegacyCLICleanupLeavesTheUsersOwnFilesAlone() throws {
        let directory = try makeDirectory("bin")
        // A user's own script under the old name, and a link to something that isn't ours.
        let script = directory.appending(path: "appfeedback")
        try Data("#!/bin/sh\necho mine\n".utf8).write(to: script)
        let otherDirectory = try makeDirectory("other")
        let foreignLink = otherDirectory.appending(path: "appfeedback")
        try FileManager.default.createSymbolicLink(at: foreignLink,
                                                   withDestinationURL: try makeBinary(named: "tool"))

        XCTAssertTrue(CLIInstaller.legacyCLILinks(in: [directory, otherDirectory]).isEmpty)
        _ = try CLIInstaller.installCLI(candidates: [directory], binary: try makeBinary())
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: foreignLink.path))
    }

    func testInstallSkillRemovesThePreRenameSkillLink() throws {
        let skills = try makeDirectory("home/.claude/skills")
        let oldSource = try makeDirectory("Old/AppFeedback.app/Contents/Resources/Skill/appfeedback")
        let legacy = skills.appending(path: "appfeedback")
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: oldSource)
        let newSource = try makeDirectory("Skill/loveletter")

        _ = try CLIInstaller.installSkill(source: newSource,
                                          destination: skills.appending(path: "loveletter"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: legacy.path))
    }

    func testLegacySkillCleanupLeavesAHandWrittenFolderAlone() throws {
        let skills = try makeDirectory("home/.claude/skills")
        let handWritten = try makeDirectory("home/.claude/skills/appfeedback")
        _ = try CLIInstaller.installSkill(source: try makeDirectory("Skill/loveletter"),
                                          destination: skills.appending(path: "loveletter"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: handWritten.path))
    }

    /// Exec'ing through the installed symlink makes `Bundle.main` point at the symlink's
    /// directory, not the .app — which is why version read as "?" and the skill folder
    /// couldn't be found. The bundle must be resolved from argv[0] instead.
    func testAppBundleResolvesToARealBundle() {
        let bundle = CLIBranding.appBundle
        XCTAssertNotNil(bundle.bundleURL)
        // In the test host this is the app bundle itself, so it must carry an Info.plist.
        XCTAssertNotNil(bundle.infoDictionary?["CFBundleIdentifier"])
    }

    /// Opt-in: exercises the real install paths against the real home directory, which is what
    /// the Settings buttons do. Off by default so a normal test run never writes there.
    /// Enable with `LOVELETTER_LIVE_INSTALL=1`.
    func testLiveInstallIntoTheRealDestinations() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOVELETTER_LIVE_INSTALL"] == "1",
                          "set LOVELETTER_LIVE_INSTALL=1 to run the real install")

        let cli = try CLIInstaller.installCLI()
        print("installed CLI at \(cli.path) -> "
              + (try FileManager.default.destinationOfSymbolicLink(atPath: cli.path)))
        guard case .installed = CLIInstaller.cliStatus() else {
            return XCTFail("cliStatus should report installed")
        }

        let skill = try CLIInstaller.installSkill()
        print("installed skill at \(skill.path) -> "
              + (try FileManager.default.destinationOfSymbolicLink(atPath: skill.path)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.appending(path: "SKILL.md").path),
                      "SKILL.md must be reachable through the installed link")
        guard case .installed = CLIInstaller.skillStatus() else {
            return XCTFail("skillStatus should report installed")
        }
    }
}
#endif

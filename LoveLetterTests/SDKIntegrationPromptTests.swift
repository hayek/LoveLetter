import XCTest
@testable import LoveLetter

final class SDKIntegrationPromptTests: XCTestCase {

    /// The agent finishes by adding the product through the CLI, with the token on stdin only.
    func testIntegrationPromptAddsTheProductThroughTheCLI() {
        let prompt = SDKIntegrationPrompt.text
        XCTAssertTrue(prompt.contains("\(CLIBranding.commandName) products add --repo"))
        XCTAssertTrue(prompt.contains("--token-stdin"))
        XCTAssertTrue(prompt.contains("Settings → Products"), "the manual path stays as the fallback")
        XCTAssertTrue(prompt.contains("CLI & AI Skill"), "and says where to install the CLI")
    }

    /// Copied from the wizard before the product exists (and the wizard can be cancelled), so
    /// the prompt must not claim the product is already there — it checks instead.
    func testWizardPromptLeavesAddingToTheUserButChecks() {
        let prompt = SDKIntegrationPrompt.text(owner: "o", repo: "r")
        XCTAssertTrue(prompt.hasPrefix("The feedback repository is already chosen: `o/r`"))
        XCTAssertFalse(prompt.contains("already chosen and added"))
        XCTAssertTrue(prompt.contains("don't add the product unless I ask"))
        XCTAssertTrue(prompt.contains("run `\(CLIBranding.commandName) products`"))
        XCTAssertTrue(prompt.hasSuffix(SDKIntegrationPrompt.text))
    }
}

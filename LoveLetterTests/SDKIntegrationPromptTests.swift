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

    func testPromptForAnExistingProductSkipsAddingIt() {
        let prompt = SDKIntegrationPrompt.text(owner: "o", repo: "r")
        XCTAssertTrue(prompt.hasPrefix("The feedback repository is already chosen"))
        XCTAssertTrue(prompt.contains("skip adding the product to Love Letter in section 6"))
        XCTAssertTrue(prompt.hasSuffix(SDKIntegrationPrompt.text))
    }
}

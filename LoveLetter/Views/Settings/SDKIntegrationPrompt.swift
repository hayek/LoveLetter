import Foundation

/// A prompt the developer pastes into an AI coding agent (Claude Code, Codex, Cursor…) opened in
/// their app's project. It drives an interactive session that adds a Love Letter SDK to the app,
/// sets up the GitHub repository the feedback lands in, and adds that repository to Love Letter
/// as a product through the `loveletter` CLI.
enum SDKIntegrationPrompt {
    /// The prompt copied from the Add Product wizard: the repository is decided, so the agent
    /// skips choosing or creating one and wires the SDK straight to it. The product is copied
    /// *before* the wizard creates it — and the user may cancel — so section 6 still checks
    /// `loveletter products` rather than assuming it exists.
    static func text(owner: String, repo: String) -> String {
        """
        The feedback repository is already chosen: `\(owner)/\(repo)`, and I'm adding it to \
        Love Letter myself. Use it — skip creating or choosing a repository in section 2 (still \
        make sure its labels exist). In section 6 don't add the product unless I ask: run \
        `loveletter products` and, if `\(owner)/\(repo)` isn't listed, remind me to finish \
        adding it in Love Letter; then hand off.


        """ + text
    }

    static let text = """
    You are helping me add in-app feedback to this project with the Love Letter SDK. Users will \
    send bug reports and feature requests from inside the app; each one becomes a GitHub issue in \
    a repository I choose, and I read them in the Love Letter inbox app.

    Work with me interactively. Ask one short question at a time, wait for my answer, and never \
    guess about anything below that is marked ASK. Before changing files, show me a short plan \
    and wait for my go-ahead.

    ## 1. Understand the project
    Inspect this project and tell me what you found:
    - Platform: Apple (Xcode project, XcodeGen `project.yml`, or `Package.swift`), Android \
    (Gradle), or Web (`package.json` — note the framework: React, plain JS, etc.). A project can \
    have more than one; if so, ASK which to integrate first.
    - The app's display name and version, and where settings/help/menu entries live — that's \
    where the "Send Feedback" entry will go.
    If this folder isn't an app project, ASK where the app is.

    ## 2. The feedback repository
    Feedback is stored as issues in a GitHub repository. ASK whether to use an existing \
    repository or create a new one. For a new one, ASK:
    - which account or organization owns it,
    - its name (suggest `<app-name>-feedback`),
    - whether it's private (recommend private — reports can contain user email addresses).
    Create it with the best tool available, in this order: a GitHub or git MCP server / skill \
    if one is connected, otherwise the `gh` CLI (`gh repo create <owner>/<name> --private \
    --description "User feedback for <App>"`; run `gh auth status` first). If neither works, \
    give me the exact steps to create it on github.com and wait until I confirm.
    Then make sure the labels `bug`, `feature-request` and `user-submitted` exist (the SDK applies them).
    Love Letter reads this repository through a GitHub account connected in the app, so pick an \
    owner that account can access (you'll add the product to Love Letter in section 6).

    ## 3. Credentials
    ASK how submissions should reach GitHub:
    - Direct: the app holds a GitHub token. Simple, but the token can be extracted from the app \
    binary. Use a fine-grained personal access token limited to the feedback repository only, \
    with Issues: Read and write (add Contents: Read and write if we enable screenshot \
    attachments). Fine for internal tools and betas.
    - Relay (recommended for public apps; required on the Web): the app posts to an endpoint I \
    host, and only the server holds the token. The web SDK's `@loveletter/relay` package has \
    ready handlers for Cloudflare Workers, Firebase, Appwrite and any fetch-style runtime.
    I create the token myself — never ask me to paste it into this chat. Load it from a secret \
    that stays out of git (Keychain, an xcconfig or `local.properties` listed in `.gitignore`, \
    or a server environment variable), and check `.gitignore` before you finish.

    ## 4. Install and wire up the SDK
    Docs: https://hayek.github.io/loveletter-docs/ — read the page for this platform before \
    writing code, and follow it over this summary if they differ.

    Apple (iOS, macOS, watchOS, tvOS, visionOS) — https://github.com/hayek/LoveLetterSDK
    - Add the Swift package `https://github.com/hayek/LoveLetterSDK` (latest release) with the \
    `LoveLetterCore` product, plus `LoveLetterUI` for the ready-made SwiftUI sheet. Use the \
    method the project already uses: `packages:` in XcodeGen's `project.yml` (then regenerate), \
    `dependencies` in `Package.swift`, or Xcode's File > Add Package Dependencies (tell me the \
    clicks if you can't edit the project file safely).
    - Build one `FeedbackClient(appName:transport:)` at app start with `GitHubDirectTransport(\
    owner:repo:token:)` or `RelayTransport(endpoint:)`, and present \
    `FeedbackSheet(client:)` in a `.sheet` from a "Send Feedback" button or menu item.

    Android — https://github.com/hayek/loveletter-android
    - Modules: core `io.github.hayek:loveletter-android` and Compose UI \
    `io.github.hayek:loveletter-android-compose` (minSdk 24). Check the README for whether \
    they're on Maven Central yet; if not, ASK whether to include the repository as a Gradle \
    composite build or wait.
    - Build a client with `androidFeedbackClient(transport:, appName:, appVersion:)` and show \
    `FeedbackSheet(client = …)` in a modal bottom sheet.

    Web — https://github.com/hayek/loveletter-web
    - Packages: `@loveletter/core`, `@loveletter/widget` (framework-free form), \
    `@loveletter/react` (`<FeedbackForm>`), and `@loveletter/relay` for the server. Check \
    whether they're published to npm; if not, ASK how to consume the workspace.
    - Always use `RelayTransport({ endpoint })` in the browser and deploy the relay for me (ASK \
    which host). Never ship a GitHub token to the browser.

    Keep the SDK's default issue format — the inbox parses it. Match the app's existing code \
    style, and put the feedback entry point where I agreed.

    ## 5. Verify
    Build the project and fix any errors. Then ask me to send one test report from the running \
    app, and confirm the issue appeared in the repository (`gh issue list -R <owner>/<repo>` or \
    the MCP server). Offer to close the test issue.

    ## 6. Add the product to Love Letter and hand off
    The feedback only reaches my inbox once the repository is a product in Love Letter. Add it \
    yourself with the `loveletter` CLI:
    - Find it: `command -v loveletter`, else `~/.local/bin/loveletter`. If neither exists, skip \
    to the fallback below.
    - Run `loveletter products`. If a product already uses `<owner>/<repo>`, it's done — skip \
    to the hand-off. Exit code 6 means Love Letter isn't running: ask me to open it, then retry.
    - ASK what to call the product (suggest the app's display name), then run \
    `loveletter products add --repo <owner>/<repo> --name "<App Name>"`. With no token flag, \
    Love Letter uses a GitHub account connected in the app that can see the repository.
    - If that fails because no connected account can see it (exit code 4, or a `missing_flag` \
    error), the product needs a token with Issues: Read and write on the repository. With my \
    OK, pipe one in on stdin — never as an argument and never echoed: the token from section 3 \
    read straight from where it's stored, or `gh auth token | loveletter products add --repo \
    <owner>/<repo> --name "<App Name>" --token-stdin`. The token is kept in my Keychain.
    - Check the JSON it prints (`repo`, `id`), and read any `error.hint` before retrying. \
    `loveletter products --help` lists the other options (color, App Store reviews, a feedback \
    email inbox) if I want them.
    Fallback, when the CLI isn't installed: tell me to install it from Love Letter → Settings → \
    CLI & AI Skill → Install and re-run this step, or add the product by hand: Settings → \
    Products → + (pick or enter `<owner>/<repo>`).

    Then tell me what changed, where the secret lives, and whether the product was added. If \
    this is a git repository, offer to commit the integration — stage only the files you changed.
    """
}

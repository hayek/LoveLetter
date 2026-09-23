---
name: loveletter
description: Read and act on real user feedback for the developer's apps — bug reports, feature requests, App Store reviews and support emails — plus the tasks, versions and releases tracking them. Use when asked what users are reporting, whether something is already tracked, what to build next, to reply to a reporter, to plan or ship a release, or to add and configure a product in Love Letter.
---

The `loveletter` CLI drives the Love Letter inbox: user feedback from the in-app SDK,
App Store reviews and support email, the tasks that track it, the versions those tasks ship
in, and the products themselves. It can do everything the app can, except sign in to GitHub
and change app-wide settings.

Output is JSON on stdout by default. `--text` is for humans — never parse it.
Almost every command needs `--product`, so **always start with `products`**.
`loveletter help <command>` (or `<command> --help`) prints every flag.

If `loveletter` isn't on PATH, use the full path shown in the app's
Settings → CLI & AI Skill pane (usually `~/.local/bin/loveletter`).

## 1. Pick the product

    loveletter products

Match the `connectedRepo` field against the current repo:

    git remote get-url origin

If nothing matches, or several do, **ask the user which product** — never guess. If the
repo the user is working on has no product yet, offer to add one (section 7).
Each product is one app backed by one repo; products that share a `repo` return identical
feedback, so pick by `id` when two of them do.

## 2. Read feedback

    loveletter feedback --product "Usage for Claude" --limit 20
    loveletter feedback --product "Usage for Claude" --label bug --since 14d
    loveletter feedback --product "Usage for Claude" --source app-store --max-rating 2
    loveletter feedback --product "Usage for Claude" --search "crash" --no-task
    loveletter feedback show 559 --product "Usage for Claude"

Filters: `--state open|closed|all` `--source sdk|app-store|email`
`--label` `--search` `--since 7d|YYYY-MM-DD` `--updated-since`
`--min-rating` `--max-rating` `--app-version` `--has-task` `--no-task` `--unread`
`--sort created|updated` `--order desc|asc` `--limit` (max 200) `--offset`.

Repeating a flag ORs its values (`--label A --label B`); different flags AND together.

`list` truncates `description` at 500 characters and sets `"truncated": true` — use
`feedback show` for the full text. Keep paging while `page.hasMore` is true.

Each item carries `unread` — not yet opened in Love Letter. Mark items read once the user
has actually seen them (not just because you read them):

    loveletter feedback mark-read --product "Usage for Claude" --feedback 559,560
    loveletter feedback mark-read --product "Usage for Claude" --all

When the app's AI triage has a pending suggestion (`triage.state` is `pending`), the user can
accept it (links the item to the suggested task, or creates the suggested task) or dismiss it:

    loveletter feedback triage --product "Usage for Claude" --feedback 559 --accept
    loveletter feedback triage --product "Usage for Claude" --feedback 559 --dismiss

## 3. Read tasks

    loveletter tasks --product "Usage for Claude" --status todo --status in-progress
    loveletter tasks show 557 --product "Usage for Claude"

Every feedback item carries a `tasks` array — the tasks already addressing it, with status.
That is the fastest way to answer "is this being worked on?".

## 4. Before creating a task

Duplicates are the main failure mode here. Both checks are required:

1. If the feedback item's `tasks` array is **not empty**, use `tasks link` — do not create.
2. Run `tasks list --status todo --status in-progress` and scan for an existing task covering
   the same theme. If one exists, link to it.

Only when both come up empty:

    loveletter tasks create --product "Usage for Claude" --title "Fix crash on launch" \
        --notes "Several reports on 1.4.2" --priority high --feedback 559,560

    loveletter tasks link   --product "Usage for Claude" --task 557 --feedback 561
    loveletter tasks unlink --product "Usage for Claude" --task 557 --feedback 561

`tasks create` writes to GitHub immediately. `--version` must name a version that already has
a GitHub milestone (see `versions`).

Edit a task — only the fields you pass change; the linked-feedback block is preserved:

    loveletter tasks update --product "Usage for Claude" --task 557 --status in-progress
    loveletter tasks update --product "Usage for Claude" --task 557 --version 1.4.3
    loveletter tasks update --product "Usage for Claude" --task 557 --no-version
    loveletter tasks update --product "Usage for Claude" --task 557 --title "…" --notes "…" --priority high

`--status done` closes the issue; any other status reopens it. Deleting permanently deletes
the GitHub issue, so confirm with the user first:

    loveletter tasks delete --product "Usage for Claude" --task 557 --yes

## 5. Replying — always ask first

    loveletter respond --product "Usage for Claude" --feedback 559 --body "Fixed in 1.4.3."

**`respond` sends immediately and cannot be undone.** It reaches a real user by email, or
posts a public App Store developer response.

Before every call: draft the reply, **show the user the exact text you intend to send, and
send only after they explicitly agree.** Never send on your own initiative, and never send a
reply you have not shown them.

`--via auto` (the default) picks the channel: App Store reviews get a developer response,
anything with an email address gets an email reply. `--via comment` posts a GitHub comment on
the feedback issue instead — that one is internal and does not reach the user.

`--template <title>` uses one of the saved reply templates instead of `--body`. Re-running
`respond` on an App Store review replaces its developer response;
`respond --product … --feedback 559 --delete --yes` removes it (ask first — it's public).

Saved templates:

    loveletter templates --product "Usage for Claude"
    loveletter templates create --product "Usage for Claude" --title "Fixed" --body "Fixed in {version}…"
    loveletter templates update --product "Usage for Claude" --template "Fixed" --body "…"
    loveletter templates delete --product "Usage for Claude" --template "Fixed" --yes

## 6. Versions and releases

A version is a GitHub milestone; tasks join it with `tasks update --version`.

    loveletter versions --product "Usage for Claude"
    loveletter versions show --product "Usage for Claude" --version 1.4.3
    loveletter versions create --product "Usage for Claude" --version 1.4.3 --title "Sync fixes" \
        --changelog "Faster sync, fewer crashes"
    loveletter versions update --product "Usage for Claude" --version 1.4.3 --changelog "…"
    loveletter versions update --product "Usage for Claude" --version 1.4.3 --name 1.5.0   # rename
    loveletter versions delete --product "Usage for Claude" --version 1.4.3 --yes

`state` is `new` (no task started), `wip` or `released`.

**Releasing emails real users and publishes a GitHub release. It cannot be undone.**
(Without a mail account in Love Letter it only closes the milestone — see below.)
Always preview first, show the user who will be emailed and the message, and release only
after they explicitly agree:

    loveletter versions recipients --product "Usage for Claude" --version 1.4.3
    loveletter versions release --product "Usage for Claude" --version 1.4.3 --yes

Recipients are the reporters of feedback linked to the version's **done** tasks — so mark
tasks done and link their feedback before releasing. `release` emails each one (threaded
into their feedback conversation), then closes the milestone and publishes release
`v<version>`. Reporters already emailed for this version are skipped unless `--resend`.
Narrow with `--recipient <email>` / `--skip <email>` (use `--include-emails` on
`recipients` to see full addresses). `--subject` / `--body` replace the default message;
placeholders: `{appName}` `{version}` `{whatsNew}` `{theirFeedbacks}`. `--no-email` releases
without emailing anyone. Without a mail account in Love Letter, a release only closes the
milestone (the app's "Mark released (no email)"): **no GitHub release is published** — the
result has `"githubRelease": false` and a warning; tell the user. `--no-email` with a mail
account still publishes the GitHub release.

## 7. Products and their sources

    loveletter accounts        # GitHub and mail accounts connected in Love Letter

Add a product for a GitHub repository (the one the SDK files feedback into):

    loveletter products add --repo owner/repo --name "My App" [--color rose]

To create a new feedback repository and add it in one go, add `--create-repo` (private unless
`--public`; ask which). Love Letter creates it with the SDK's labels (`bug`, `feature-request`,
`user-submitted`) using the connected account that owns it — or an organization member account —
then adds the product. `repo_exists` (exit 1) means the name is taken: drop `--create-repo` to
add that repository as it is, or pick another name.

    loveletter products add --repo owner/myapp-feedback --name "My App" --create-repo

**Never put a token on the command line.** With no token flag, Love Letter uses a connected
GitHub account that can see the repository (`--account <login>` picks one). Otherwise pipe a
token with Issues read/write access on stdin — `gh auth token | loveletter products add
--repo owner/repo --token-stdin` — and only with the user's OK. The repo is checked before
anything is saved; exit 4 means no token could see it, and `missing_flag` (exit 1) means no
GitHub account is connected, so a token must be piped.

    loveletter products update --product "My App" --name "…" --color sky \
        --mirror-emails on|off --redact-emails on|off [--token-stdin | --account <login>]
    loveletter products remove --product "My App" --yes      # ask first

App Store reviews (an App Store Connect API key; the `.p8` is read from disk and kept in the
Keychain). The key is verified first; pass `--app-id` when it can see several apps:

    loveletter products app-store --product "My App" --issuer-id … --key-id … \
        --p8 ~/Downloads/AuthKey_XXXX.p8 [--app-id 1234567890]

A feedback email inbox (the password is piped, and the login is tested before saving):

    security find-generic-password -s … -w | loveletter products email --product "My App" \
        --preset gmail|icloud|outlook|custom --address feedback@myapp.com --password-stdin
    loveletter products email --product "My App" --remove --yes

`--preset custom` also needs `--imap-host` and `--smtp-host` (and optionally ports).

## 8. Freshness

Every response carries `asOf` and `stale`. Data comes from the app's local cache, which
refreshes every 15 minutes while Love Letter is running.

- Add `--refresh` to any read command to make the app poll GitHub first.
- Exit code 6 means Love Letter isn't running — ask the user to open it. Writes and
  `--refresh` both need it; plain reads work without it.
- After `tasks create`, the new task will **not** appear in `tasks list` until a refresh
  succeeds. Trust the create response — don't re-query to "verify" it.

## 9. Writes and confirmation

Every write goes through the running app, which does exactly what its own UI does.
Destructive or outward-facing writes — `products remove`, `products email --remove`,
`tasks delete`, `versions delete`, `versions release`, `templates delete`,
`respond --delete` — refuse to run without `--yes` (error code `confirmation_required`).
Get the user's explicit agreement before adding `--yes`; never add it on your own initiative.

## 10. Data honesty

- `--state closed` and `--state all` set `"closedDataIncomplete": true`. The cache is
  open-issue-centric: issues closed before the app ever saw them were never cached, and a
  cached `closed` can also mean *deleted upstream*. Open-state results are complete.
- `triage` is the app's own local AI advice, not ground truth. Its `kind` vocabulary
  (`bug|featureRequest|usability`) is **different** from the `bug` / `feature-request`
  labels, which are ordinary labels like any other. Don't conflate them.
- Reporter emails are redacted (`a***@icloud.com`). `--include-emails` returns them in full;
  only use it when the user has asked you to contact someone.

## Vocabularies

| Field | Values |
|---|---|
| status | `todo` `in-progress` `done` |
| priority | `low` `med` `high` |
| source | `sdk` `app-store` `email` |
| state | `open` `closed` `all` |
| version state | `new` `wip` `released` |
| mail preset | `gmail` `icloud` `outlook` `custom` |

## Exit codes

`0` ok · `1` usage · `2` not found · `3` no local data (launch the app once) ·
`4` auth · `5` remote failure · `6` app not running · `7` timeout.

Errors are JSON on stdout too, so the output parses either way. Exit 4 may mean the Mac's
screen is locked rather than a missing token — these credentials sync via iCloud Keychain and
can't be read while locked. Read the `hint` field before acting on any error.

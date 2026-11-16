# gsadv — Git Security Advisories

Manage GitHub security advisories and GitLab disclosure issues from the command line.
Written in [V](https://vlang.io).

Turn a fix commit, issue or pull/merge request into a reviewed security disclosure.
An AI agent does the reconstruction; you keep the last word.

```sh
$ cd ~/radare2
$ gsadv new 8f3a2c1 found by fuzzing the PDB parser
```

## What it does

- Lists advisories/disclosures, local commits, issues and PRs/MRs in separate tabs.
- Drafts an advisory from a commit or GitHub/GitLab issue/PR/MR URL: the agent reads the report,
  discussion, patch, history and tags, then writes root cause, CWE, CVSS and versions.
  Evidence, caveats and related finding references belong in the advisory text.
  Drafting and review fill missing credits from verified sources and preserve names and scan IDs
  in Acknowledgements when they cannot be represented as GitHub credits.
- Reviews existing advisories with the agent as a diff you accept or reject line by line.
- Finds similar bugs using an advisory, CVE or fix commit as a template for an AI search.
- On GitHub, manages credits (finders, reporters, fix authors, ...) in a TUI screen.
- On GitHub, requests CVEs, accepts private reports, publishes and closes advisories. TUI actions confirm.
- Saves accepted CVE requests locally, preserving `requested*` across restarts until a CVE is assigned.
- Tags individual advisories, commits and issues/PRs as invalid locally, with a reason and undo.

Advisories are plain text in `$EDITOR` — no JSON, no web forms.

GitLab repositories are detected from their Git remote or source URL. Authenticate with
`glab auth login`; `new` creates a **confidential issue** labeled `security-advisory`.
Use `GL-123` to show, edit, review, close or reopen that disclosure. `cve GL-123` explains
GitLab's CVE request process; it does not submit a request. GitLab has no equivalent to
GitHub's advisory publishing endpoint, so `publish`, `draft` and structured `credits`
remain GitHub-only. GitLab Ultimate vulnerability reports are not required or queried.
Custom servers use `--provider gitlab -r https://code.example/group/project`.
Use `--remote name` to choose another Git remote. The tool was renamed from `ghadv`
to `gsadv`; configuration now uses `GSADV_*`, with `GHADV_*` aliases still supported.
See the [GitLab guide](doc/gitlab.md) for setup,
state/visibility differences, CVE tracking and limitations.

Codeberg is not supported yet. It has [API and CLI access through `tea` or `fj`](https://docs.codeberg.org/git/clone-commit-via-cli/#cli-clients-tea-and-fj-for-other-actions),
but its [current API schema](https://codeberg.org/swagger.v1.json) exposes neither
repository security advisories nor confidential issues. General issue access alone
does not provide the private disclosure workflow used by gsadv.

## Install

Requires `git` and the authenticated CLI for your provider:
`gh` with **Repository security advisories: write** for GitHub, or `glab` with access
to the project issues for GitLab. GitLab Ultimate is not required.

Download a platform archive from [Releases](https://github.com/trufae/gsadv/releases),
extract it, and install the `gsadv` executable somewhere on `PATH` (for example,
`install -m 755 gsadv ~/.local/bin/gsadv` after creating `~/.local/bin`).
Archives include the executable, version and documentation; `SHA256SUMS` lists their
checksums. The Linux musl executable is statically linked.

To build from source, install [V](https://vlang.io), then:

```sh
git clone https://github.com/trufae/gsadv.git && cd gsadv
make BIN=gsadv install   # builds and installs gsadv into ~/.local/bin
```

Or build only: `make` (defaults to `gsadv`), or `v -o gsadv src`. `BIN`, `PREFIX` and
`BINDIR` are overridable; `make uninstall` and `make clean` exist. Use the same `BIN`
value for install, uninstall and clean.

V source files and unit tests live in `src/`. Run the unit tests with `v test src`.

Check the installed version with `gsadv --version` (also `-v` or `version`).
The first release reports `gsadv 0.1.0`; version and help work without a repository
or provider CLI. Builds embed the version from [VERSION](VERSION).

The [CI workflow](.github/workflows/ci.yml) builds and tests `gsadv` on macOS and
Alpine Linux (musl) for branch pushes and pull requests, and can also be run manually.
Both jobs use the latest V source: macOS installs it with `vlang/setup-v`, while
Alpine builds it inside an Alpine container. They run the unit tests, `--help`, `--version`,
and the offline GitHub/GitLab smoke checks with stub provider CLIs.
Each successful platform job uploads its `.tar.gz` package as a CI artifact; filenames
include the platform and architecture (`gsadv-macos-arm64.tar.gz` and
`gsadv-linux-musl-x86_64.tar.gz` on the current runners).

Pushing any tag starting with a digit (for example, `0.1.0`) runs the same checks and,
after both platform jobs pass, creates a GitHub release with all platform archives,
checksums and generated release notes. Branch pushes, pull requests and manual runs
upload CI artifacts without publishing a release. To release, update `VERSION`, commit
the changes, then tag and push that commit:

```sh
git tag -a 0.1.0 -m 'Release 0.1.0'
git push origin main 0.1.0
```

## Usage

```sh
gsadv [-r namespace/repo|url] [--provider github|gitlab] [--host hostname] [--remote name] [command] [args]
```

Run `gsadv` with no arguments for the TUI: advisories/disclosures, commits, issues,
and PRs (MRs on GitLab) each have their own tab. Searches, selections and scrolling
are independent. The issue and PR/MR headers show `label: cve` by default, or
`all labels` with `--label ''`. Press `l` to change the shared label filter for the
current TUI session. Enter applies; Ctrl+U then Enter shows all labels; Escape cancels.
The screen opens immediately while repository detection, remote lists and local Git
details load in background threads. Each tab becomes usable as its data arrives;
navigation and quitting stay responsive during loading and reloads. Reload failures
keep the previous list. Searches, advisory links and formatted rows are cached, so
moving the selection does not rescan the lists or reformat unchanged rows.
Use `Tab` to cycle tabs forward and `Shift-Tab` to cycle backward, wrapping at either end.
Tabs occupy their own second row, with the active tab highlighted in inverse colors.
The top row shows the repository and local checkout's
latest commit (hash and subject), plus clean, unstaged, staged, untracked or conflicted
status. Git details refresh with `g` and after returning from a viewer, editor or AI workflow.
The TUI adapts to narrow and short terminals, keeps the selection visible when resized,
and refreshes changed rows without clearing the screen. Small widths use compact rows;
open an entry to read its full text. Menus and help scroll with `j`/`k` or the mouse wheel.
The advisory list and `ls` include **FIXED IN** and **RELEASE** columns. Recorded patched
versions are checked against repository releases. Each RELEASE cell uses one emoji:
🟢 `released`, 🟡 `prerelease`, 🔵 `draft`, 🟠 `upcoming` (GitLab), or 🔴 `no release`
(no matching release tag). Missing versions, version ranges that cannot be matched
exactly, and failed release lookups show ⚪ `unknown`; advisories with different
results across patched versions show 🟣 `mixed`.
The TUI selection line shows each version's result and the recorded affected ranges.
Use `/` to filter by a fix version or release status; the tab count shows matching
advisories within the current state filter. `g` refreshes the release check.
Columns appear at 80+ terminal columns; CVE and severity text appear at 120+.
Matching accepts an optional `v` prefix, but does not infer fixes from local tags,
compare ecosystem-specific version ranges, or verify package registry availability.
A missing fix release does not prove the bug was introduced since the last release:
check the affected range to distinguish released-build bugs from development-only bugs.
Release visibility also follows repository access; these indicators do not automatically
approve publication. See [list details](doc/usage.md#ls).
Key commands:

| Command | What |
| --- | --- |
| `tui [label]` | interactive TUI (default) |
| `ls [state]` | list advisories or GitLab disclosure issues |
| `log` | list fix commits and their advisories |
| `issues [label]` | list labeled issues/PRs/MRs |
| `new <commit\|url> [context]` | analyze and create a draft |
| `show <id>` | print an advisory |
| `status <id>` | lifecycle, CVE and report details |
| `credits <id>` | manage GitHub credits in the TUI |
| `edit <id>` | edit in `$EDITOR` |
| `review <id\|commit\|url> [context]` | AI review an advisory or source, then edit |
| `comment <issue\|PR URL> [text]` | edit and confirm a discussion comment |
| `similar <id\|commit\|url> [context]` | find similar bugs |
| `resume <dir>` | continue saved work |
| `recover <log\|dir>` | turn a saved `claude.jsonl` into Markdown when the reply is lost |
| `cve <id>` | request a GitHub CVE or show GitLab request instructions |
| `close/reopen <id>` | close or reopen an advisory/disclosure |
| `draft/publish <id>` | change GitHub advisory state |
| `invalid <id\|commit\|url> [reason]` | show a local invalid tag, or set it with a reason |
| `unmark <id\|commit\|url>` | remove a local invalid tag |

For example, `gsadv invalid GHSA-xxxx-yyyy-zzzz "No tagged release shipped vulnerable code"`
records a local triage decision. In the TUI, `i` marks the selected item or edits its reason,
and `I` removes the tag. Lists show `[invalid]`; `/` searches both the tag and its reason.
Tags survive restarts and apply only to the selected item, independently of linked items.
They do not change GitHub or GitLab. To record an advisory decision upstream, use `edit` to explain
the finding in its description, then `close` to reject an unpublished advisory/report.
See [invalid tags](doc/usage.md#invalid--unmark).

The `log` command and TUI commit tab include commits tagged `##crash`, `##security`,
`##vulnerability` or `##sandbox` by default. Override the pattern with `GSADV_GREP`.
The issue/PR/MR list defaults to the `cve` label. Use `--grep` and `--label` before
the command to override these filters; an empty value disables the corresponding filter:

```sh
gsadv --label '' --grep ''              # browse all issues/PRs and the latest 2000 commits
gsadv --label bug --grep 'fix|security'  # use another repository's conventions
git config --local gsadv.label ''       # keep unlabelled PRs visible in this checkout
git config --local gsadv.grep 'fix|bug'  # repository-specific commit pattern
gsadv review https://github.com/owner/repo/pull/123 "Check error handling"
gsadv comment https://github.com/owner/repo/pull/123
```

Source reviews use the diff and discussion without needing labels or a linked advisory.
In the commit or issue/PR/MR tab, `r` reviews the selected source; `M` composes a comment
on the selected issue/PR/MR. Reviews open in `$EDITOR`, then show a preview and ask before
posting a discussion comment. Commit reviews stay as local reports. Empty the editor to
cancel; `resume <directory>` reopens saved text without running the AI again. Posting
receipts prevent a later resume from posting the same saved comment again.

Configuration lives in `GSADV_REPO`, `GSADV_LABEL`, `GSADV_AI`, `GSADV_GREP`, plus `$EDITOR`
and `$PAGER`. Environment variables override `git config gsadv.<name>` defaults.
See [doc/configuration.md](doc/configuration.md).

AI workflows show live progress on stderr and an elapsed-time update every 10 seconds.
The Claude preset shows messages, Bash commands and descriptions, file paths and search
arguments; Codex uses its native stderr output, and the pmai preset uses `--progress`
(requires a pmai version with that option).
Replies stay separate in the recovery directory for review and editing. See
[AI progress and recovery](doc/ai-agent.md#progress-and-recovery).

## Documentation

| Page | Content |
| --- | --- |
| [doc/gitlab.md](doc/gitlab.md) | GitLab setup, disclosures, CVEs and limitations |
| [doc/usage.md](doc/usage.md) | every command and a typical end-to-end flow |
| [doc/tui.md](doc/tui.md) | views and all keybindings |
| [doc/advisory-format.md](doc/advisory-format.md) | the text format and the review diff rules |
| [doc/ai-agent.md](doc/ai-agent.md) | how the agent is prompted and what it checks |
| [doc/configuration.md](doc/configuration.md) | `GSADV_*`, `EDITOR`, `PAGER`, permissions |
| [doc/how-it-works.md](doc/how-it-works.md) | API endpoints and commit linking |
| [doc/design-notes.md](doc/design-notes.md) | why it works this way, and limitations |

See the repository for license terms.

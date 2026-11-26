# gsadv

A CLI and terminal UI for managing GitHub security advisories and GitLab security
disclosures, written in [V](https://vlang.io).

- Browse advisories, fix commits, issues and pull/merge requests.
- Use AI to draft and review disclosures from commits or issue/PR/MR URLs, and
  search for similar bugs.
- Edit advisories as plain text in your editor and review changes before accepting them.
- Request CVEs and publish advisories on GitHub; manage confidential disclosure
  issues on GitLab.

Run `gsadv` inside a repository to open the terminal UI.
Press `N` to write a draft by hand in `$EDITOR`, starting from an advisory template.
Fill in the fields and sections or paste a complete advisory; leaving the template
unchanged or emptying it cancels. `gsadv new` opens the same template from the CLI.
Lowercase `n` opens a menu: `a` generates a new advisory with AI from the selected
commit, issue or PR/MR (`gsadv new <commit|url>`), `m` writes a manual draft like `N`,
and `i` imports an `ADVISORY.md` when one is available (see the Reports tab below).
Press `a` for the actions that apply to the selected item in the current tab
(similar bugs, credits, CVE and state changes, comments, ...); each still has its
direct key, listed in `?` help.
In the PRs/MRs tab, `R` asks the AI to review the selected pull/merge request for its
contributor: merge blockers, logic bugs and similar bugs nearby, questions about the
approach and follow-ups, written as a short comment. You edit it in `$EDITOR` and
confirm before gsadv posts it (`gsadv pr-review <PR URL|number> [context]`).
Use `J`/`K` or AvPág/RePág (Page Down/Page Up) to move down/up ten rows.
Switch to the next/previous tab with Tab/Shift-Tab, `l`/`h` or the right/left arrows.
`H`/`L` jump to the first/last tab.

The document viewer shows Markdown in terminal colors. Use `j`/`k`, the arrows,
the mouse wheel or Page Down/Page Up to scroll, and `g`/`G` to jump to the
beginning/end. Lines wrap to the terminal width and the viewer keeps your place
when the window resizes. Type `:w <path>` and press Enter to save the original
text to a new file. Paths can contain spaces and start with `~/`. Press `q`,
type `:q` or press Esc to close. `NO_COLOR=1` shows the source in the viewer.
Set `PAGER` to open the original text in an external pager.

The shared issue/PR/MR label filter is the `label` setting (press `,`); an empty
value shows all labels. Results appear page by page while the remaining history
loads in the background. Changing the label takes effect after the current page finishes.
In the issues or PR/MR tab, press `f` once to show only open items. Press `f` again
for closed items, or `F` to go back; GitLab MRs also have a merged filter. State
filters are remembered separately for each tab and combine with the label and
`/` (text) filters.

The commits tab only lists commits whose message matches the `grep` setting
(default `##(crash|security|vuln|sandbox)`), a `git log -E --grep` regex;
an empty value shows all commits.

The Reports tab lists every `REPORT.md` below the `antfind` directory (default
`ANTFIND` at the project root), skipping any directory named by `attic` (default
`Attic`). Rows come from the fenced header at the top of each report
(`ID  [severity]  CWE-N  class`, title and `Location:` lines) and are sorted by
severity. The severity circle uses the advisory colors; ⚫ marks reports tagged
`[NOT SECURITY]`. The type column (UAF, DOUBLE-FREE, STACK-OVF, HEAP-OVF,
OOB-READ, INT-UNDERFLOW, CMD-INJ, OOM, HANG, ...) is derived from the CWE, or from
keywords in the title or body when the CWE is missing or unknown. Press `f`/`F`
to filter by severity, Enter to read a report and `e` to edit it. `t` moves the
finding's directory into the attic next to it (`wave1/X` becomes `wave1/Attic/X`;
an `attic` value containing `/` is a path below `antfind`).

Press `a` to open the Actions menu. `f` in that menu, or
`gsadv fix <REPORT.md> [context]`, asks the AI agent to confirm the bug first:
reports may be false positives, so it must reproduce the crash or bug with a real
reproducer against code built from the checkout before changing anything. Only a
confirmed bug is fixed, with a regression test, and committed locally (never
pushed) with a subject tagged `##crash`, `##sandbox`, `##security` or `##vuln` and
the report referenced on the third line as `* OSS-SCAN - <report id>`. The reply
starts with a verdict (confirmed, false positive, already fixed or inconclusive)
and its reason, which gsadv prints after the summary; a false positive is marked
invalid with that reason, so every running gsadv shows it.

`F` in the Actions menu, or `gsadv quickfix <REPORT.md> [context]`, checks the
reported issue and suggested patch by reading the source. If inspection confirms
the issue and the patch addresses it, the agent applies and commits the patch
locally and writes `ADVISORY.md` using the evidence already in the finding
directory. Quickfix skips builds, tests and reproducers. If the patch is missing
or unsuitable, the agent reports an inconclusive result.

While either fix runs, its output is copied to `WIP.txt` next to `REPORT.md`.
The first line names the fixing process. Press `w` to read it. The summary is
then saved as `RESULT.md` (replacing
an earlier one) and `WIP.txt` is removed; after a failed or interrupted run it stays
for inspection. These files move to the attic with the finding. The STATE column
refreshes each second and shows every applicable icon.

- 🤖 Agent running or 🛑 run stopped. Press `w` to read `WIP.txt`.
- 👍 Confirmed, ❌ marked invalid or false positive, 🔧 already fixed,
  ❓ inconclusive, or ✅ finished without a verdict. Press `o` to read `RESULT.md`.
- 📝 Advisory draft exists. Press `d` to read `ADVISORY.md`.
- 🔍 Similar bugs were searched. Press `s` to read `SIMILAR.md`.

Both fix prompts point the agent at the report's directory and list its supporting
files. After committing a confirmed fix, the agent writes `ADVISORY.md` next to
the report. Press `d` to read it. If the agent leaves the draft in the checkout,
gsadv moves it next to the report. The full fix prompt includes the `antfind`
directory so the agent can check other findings for duplicates and variants.
When you later draft an advisory from the fix commit (`n`
in the commits tab or `gsadv new <commit>`), gsadv takes the finding ID from the
commit message (`* OSS-SCAN - ANT-...`), finds the finding under `antfind`, attic
included, and gives the agent its `ADVISORY.md` to trust as the starting point, or
its `REPORT.md` as evidence when there is no draft.
To skip the AI, press `n` then `i` on the fix commit (or on the report): gsadv opens
that `ADVISORY.md` in `$EDITOR` and creates the draft when you save it. From the CLI,
`gsadv import <commit|ADVISORY.md|REPORT.md>` does the same. In the commits tab and
`gsadv log`, a fix commit without a linked advisory shows `📝 ADVISORY.md` when its
finding has one ready to import.
`b`, or `gsadv similar <REPORT.md> [context]`, searches for similar bugs using the
report as a template (the agent first confirms the report's bug pattern, since it
may be a false positive) and saves the findings as `SIMILAR.md` next to the report;
`s` reads it. The default Claude preset runs fixes with
`--permission-mode acceptEdits`, and the `claude`, `codex` and `pmai` presets get
`--add-dir <report directory>` so the agent can read it and write `ADVISORY.md`
there; a custom `GSADV_AI` command uses its own permissions. The prompts are
`src/prompts/fix.txt` and `src/prompts/quickfix.txt`.

Press `,` to open the settings screen (`grep`, `label`, `antfind`, `attic`): move
with `j`/`k` or the arrows, press Enter to change a value and `d` to reset it to the
default. Changes apply when you leave the screen and are saved per project in
`.gsadv.ini` at the root of the Git checkout (or the current directory outside Git),
one `key=value` per line; `#` and `;` start comments. Other `gsadv` settings, such
as `ai`, can also be set there. The AI prompts are text files in `src/prompts`,
embedded at build time. `GSADV_*` environment variables and the `--label`/
`--grep` flags override the file for that run (the screen marks such values as not
saved), and the file overrides `git config gsadv.*`.

Press `m` to mark the selected item: `*` important, `@` work in progress, `^` pin
(listed first), `-` ignore (dimmed, listed last) or `!` invalid (requires a reason).
Each item has one mark, with an optional note and the user and time that set it,
shown below the list when the item is selected. Marks are stored in the local state
directory per repository and item, and every running `gsadv` for the repository
picks up changes within about a second, so analysts in several terminals see who
is working on what. Reports are marked by finding ID, which survives moving them to
the attic. Marks are manual triage decisions, separate from advisory and release
state. `i` and `I` remain shortcuts to set an invalid reason and remove a mark.
From the CLI, `gsadv ls`, `log` and `issues` show the mark symbols,
`gsadv invalid <id|commit|url>` reads an invalid reason and
`gsadv unmark <id|commit|url>` removes a mark.

## Install

Requires `git` and [gh](https://cli.github.com) for GitHub or
[glab](https://gitlab.com/gitlab-org/cli) for GitLab. Authenticate with
`gh auth login` or `glab auth login`. AI features use Claude by default;
set `GSADV_AI` to use another agent command.

Agent progress and completion messages show elapsed time in hours, minutes and
seconds, for example `1h 7m 30s`.

For advisory drafts and reviews, Claude's first completed advisory is kept even if
background tasks emit later follow-up messages. Waiting messages do not replace it.
The full conversation remains in the saved transcript. Failures include a copyable
`gsadv resume <directory>` command; resuming automatically restores a completed
advisory from that transcript if `reply.txt` is missing or contains no advisory.
`gsadv continue <directory>` reruns the AI of a failed action in the same saved
Claude conversation (`src/prompts/continue.txt`), so the context it gathered and
the work it already did are kept instead of starting over.

When an action started from the TUI fails, the error is repeated in red below its
output with the keys that apply: `r` retries the action from scratch, `u` resumes
it without the AI when recovery files exist, `c` continues it in the same Claude
conversation when one was saved (the default `claude -p` agent only), and Enter
returns. The error and its resume and continue commands stay in the status line
after returning.

Commit and PR analysis accepts patches containing literal terminal escape bytes,
such as terminal output test fixtures.

Download an archive from [Releases](https://github.com/trufae/gsadv/releases),
extract it, and place the `gsadv` executable in a directory on your `PATH`.

Or install a recent [V](https://vlang.io) with `vlib/x/markdown` and build from source:

```sh
git clone https://github.com/trufae/gsadv.git
cd gsadv
make install
```

This installs to `~/.local/bin`; ensure that directory is on your `PATH`.

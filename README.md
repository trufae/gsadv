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
Lowercase `n` and `gsadv new <commit|url>` draft with AI.
Use `J`/`K` or AvPág/RePág (Page Down/Page Up) to move down/up ten rows.
Switch to the next/previous tab with Tab/Shift-Tab, `l`/`h` or the right/left arrows.
The shared issue/PR/MR label filter is the `label` setting (press `,`); an empty
value shows all labels. Results appear page by page while the remaining history
loads in the background. Changing the label takes effect after the current page finishes.
In the issues or PR/MR tab, press `f` once to show only open items. Press `f` again
for closed items, or `F` to go back; GitLab MRs also have a merged filter. State
filters are remembered separately for each tab and combine with the label and
`/` (text) filters.

The commits tab only lists commits whose message matches the `grep` setting
(default `##(crash|security|vulnerability|sandbox)`), a `git log -E --grep` regex;
an empty value shows all commits.

The Reports tab lists every `REPORT.md` below the `antfind` directory (default
`ANTFIND` at the project root), skipping any directory named by `attic` (default
`Attic`). Rows come from the fenced header at the top of each report
(`ID  [severity]  CWE-N  class`, title and `Location:` lines) and are sorted by
severity. The severity circle uses the advisory colors; ⚫ marks reports tagged
`[NOT SECURITY]`. The type column (UAF, DOUBLE-FREE, STACK-OVF, HEAP-OVF,
OOB-READ, INT-UNDERFLOW, CMD-INJ, OOM, HANG, ...) is derived from the CWE, or from
keywords in the title or body when the CWE is missing or unknown. Press `f`/`F`
to filter by severity, Enter to read a report and `e` to edit it.

Press `,` to open the settings screen (`grep`, `label`, `antfind`, `attic`): move
with `j`/`k` or the arrows, press Enter to change a value and `d` to reset it to the
default. Changes apply when you leave the screen and are saved per project in
`.gsadv.ini` at the root of the Git checkout (or the current directory outside Git),
one `key=value` per line; `#` and `;` start comments. Other `gsadv` settings, such
as `ai`, can also be set there. `GSADV_*` environment variables and the `--label`/
`--grep` flags override the file for that run (the screen marks such values as not
saved), and the file overrides `git config gsadv.*`.

A `!` in the left margin marks a saved local invalid tag. These are manual triage
decisions with a reason, separate from advisory and release state. Selecting a
tagged item shows its reason below the list; press `i` to read or edit the full
reason, or `I` to clear the tag. From the CLI, use `gsadv invalid <id|commit|url>`
to read the reason and `gsadv unmark <id|commit|url>` to clear it.

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

Commit and PR analysis accepts patches containing literal terminal escape bytes,
such as terminal output test fixtures.

Download an archive from [Releases](https://github.com/trufae/gsadv/releases),
extract it, and place the `gsadv` executable in a directory on your `PATH`.

Or install [V](https://vlang.io) and build from source:

```sh
git clone https://github.com/trufae/gsadv.git
cd gsadv
make install
```

This installs to `~/.local/bin`; ensure that directory is on your `PATH`.

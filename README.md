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
Use `J`/`K` or AvPág/RePág (Page Down/Page Up) to move down/up ten rows.
Press `l` to change the shared issue/PR/MR label filter; an empty value shows all
labels. Results appear page by page while the remaining history loads in the
background. Changing the label takes effect after the current page finishes.
In the issues or PR/MR tab, press `f` once to show only open items. Press `f` again
for closed items, or `F` to go back; GitLab MRs also have a merged filter. State
filters are remembered separately for each tab and combine with `l` (label) and
`/` (text) filters.

The commits tab only lists commits whose message matches `GSADV_GREP`
(default `##(crash|security|vulnerability|sandbox)`). In that tab, press `l` to
change the `git log -E --grep` regex; an empty value shows all commits. Use
`git config --local gsadv.grep ''` to show all commits by default in a repository.

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

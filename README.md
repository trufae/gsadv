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
In the issues or PR/MR tab, press `f` once to show only open items. Press `f` again
for closed items, or `F` to go back; GitLab MRs also have a merged filter. State
filters are remembered separately for each tab and combine with `l` (label) and
`/` (text) filters.

## Install

Requires `git` and [gh](https://cli.github.com) for GitHub or
[glab](https://gitlab.com/gitlab-org/cli) for GitLab. Authenticate with
`gh auth login` or `glab auth login`. AI features use Claude by default;
set `GSADV_AI` to use another agent command.

Download an archive from [Releases](https://github.com/trufae/gsadv/releases),
extract it, and place the `gsadv` executable in a directory on your `PATH`.

Or install [V](https://vlang.io) and build from source:

```sh
git clone https://github.com/trufae/gsadv.git
cd gsadv
make install
```

This installs to `~/.local/bin`; ensure that directory is on your `PATH`.

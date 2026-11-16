# Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `GSADV_REPO` | cwd checkout | project path (`owner/repo` or `group/subgroup/repo`) or full repository URL |
| `GSADV_PROVIDER` | detect from URL/remote | `github` or `gitlab`; required for custom hosts |
| `GSADV_HOST` | URL/remote host | API server hostname, optionally with HTTPS port |
| `GSADV_REMOTE` | upstream, origin, sole remote | select a Git remote explicitly |
| `GSADV_ADVISORY_LABEL` | `security-advisory` | GitLab disclosure issue label for `ls`, the disclosures tab and `new` |
| `GSADV_GREP` | `##(crash\|security\|vulnerability\|sandbox)` | `git log -E --grep` pattern; empty includes all of the latest 2000 commits |
| `GSADV_LABEL` | `cve` | label for the issues/PRs/MRs tab and `issues`; empty includes unlabelled items; includes all states |
| `GSADV_AI` | `claude -p` | agent command, prompt on stdin; see [progress and recovery](ai-agent.md#progress-and-recovery) |
| `EDITOR` | `vi` | editor for drafts and reviews |
| `PAGER` | `less` | advisory and issue/PR viewer when `r2` is not on `PATH` |
| `XDG_STATE_HOME` | `~/.local/state` | base directory for persistent CVE request records and invalid tags |

The tool was renamed from `ghadv` to `gsadv`. Each `GSADV_*` variable takes precedence
over its legacy `GHADV_*` alias, including when explicitly set to an empty value.
Existing `GHADV_*` settings still work when the corresponding `GSADV_*` variable is unset.
Saved CVE request records and invalid tags keep their original `ghadv` directory below
`XDG_STATE_HOME`, so upgrading preserves existing data. Recovery directories created
by `ghadv` can still be opened with `gsadv resume`.

Every `GSADV_*` setting can also use Git configuration: lowercase the name and replace
underscores with hyphens, such as `gsadv.label`, `gsadv.grep` and `gsadv.advisory-label`.
Environment variables (including legacy aliases) take precedence over Git configuration;
unset values use the built-in defaults. An explicitly empty filter means all items.
Git configuration follows the current checkout, including when `-r` selects another project.

```sh
git config --local gsadv.label ''         # all issues/PRs/MRs in this checkout
git config --local gsadv.grep 'fix|bug'    # custom commit pattern
git config --global gsadv.label security  # default for your other checkouts
gsadv --label '' --grep ''                # override both filters for one run
```

`-r`, `--provider`, `--host`, `--remote`, `--label` and `--grep` override the corresponding `GSADV_*` setting.
Put them before the command. See [repository selection](gitlab.md#setup-and-repository-selection).
For `new <url>` (also `review`, `comment`, `similar`, `invalid` and `unmark`), the URL supplies the repository before the cwd checkout is consulted;
it must match an explicit `-r` or `GSADV_REPO`. `tui <label>` and `issues <label>` override
`GSADV_LABEL`. An unset label defaults to `cve`; an empty `GSADV_LABEL` or `--label ''`
removes the label filter. Quote labels containing spaces. The separate
`GSADV_ADVISORY_LABEL` continues to scope GitLab disclosures and does not disable with an empty value.

When no repository/source URL is supplied and `GSADV_HOST` is unset, `GH_HOST` supplies
the GitHub host; with `--provider gitlab`, `GITLAB_HOST` supplies the GitLab host.
An inherited `GH_HOST` also selects GitHub when no provider is set, preserving existing
GitHub configuration. Other custom hosts require a provider. Explicit URLs do not
inherit these CLI-specific host defaults. Each API request receives the resolved hostname explicitly.

When `r2` is on `PATH`, the TUI uses `r2 -q -c "cat -m file.md" --` to render
advisory and issue/PR Markdown. Press `enter` after reading to return to the list.

## Local CVE request records

After GitHub accepts a CVE request, gsadv saves its UTC timestamp in
`$XDG_STATE_HOME/ghadv/cve-requests/`, or `~/.local/state/ghadv/cve-requests/` by default.
Each file is named with a hash of the resolved GitHub host,
repository and advisory ID. These records are shared by the CLI and TUI and survive
closing the app, restarting it, or switching checkouts of the same repository.

The list shows `requested*` while a recorded request has no assigned CVE;
`gsadv status <ghsa>` shows when the request was accepted. An assigned CVE takes
precedence over the local record. Requests made through the GitHub website or raw
`gh` commands do not create these local records.

## Local invalid tags

Invalid tags and their reasons are JSON files below `$XDG_STATE_HOME/ghadv/invalid/`,
or `~/.local/state/ghadv/invalid/` by default. The resolved host and repository scope the directory;
GitLab includes an additional provider prefix in the hash to avoid collisions. Existing
GitHub record paths are preserved; a hash of the advisory ID, full commit SHA or
issue/PR URL identifies each record. IDs and URLs are compared without case sensitivity.
Tags are shared by the CLI and TUI and by checkouts of the same repository on this machine.
They are not uploaded to GitHub or GitLab. GitLab disclosure IDs (`GL-123`) and their
issue URLs share a tag. `gsadv unmark <ghsa|commit|url>` removes a record.

## Permissions

`gh` must be authenticated with **Repository security advisories: write** permission, plus
repo admin or security-manager access for the relevant GitHub operations. For GitLab,
use an authenticated `glab` account with permission to read/create/edit the project
issues. Requesting a CVE through GitLab's website requires Maintainer/Owner access
to an eligible public GitLab.com project. See [the GitLab guide](gitlab.md).

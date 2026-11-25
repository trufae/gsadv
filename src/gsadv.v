module main

import os

const version = $embed_file('../VERSION').to_string().trim_space()

// Prefer explicit environment settings, including empty values, then .gsadv.ini, then Git configuration.
fn setting(name string) ?string {
	if value := os.getenv_opt('GSADV_${name}') { return value }
	if value := os.getenv_opt('GHADV_${name}') { return value }
	values := project_ini()
	if name.to_lower() in values { return values[name.to_lower()] }
	r := os.exec(['git', 'config', '--get', 'gsadv.${name.to_lower().replace('_', '-')}'])
	if r.exit_code != 0 { return none }
	return r.output.trim_right('\r\n')
}

const help = 'Usage: gsadv [-r namespace/repo|url] [--provider github|gitlab] [--host hostname] [--remote name] [--label label] [--grep regex] [command] [args]
  --version, -v, version   print the tool version
  tui [label]              advisory, commit, issue, PR/MR and report tabs (default)
  ls [state]               GitHub advisories or GitLab disclosure issues (opened/closed)
  log                     list matching commits and their advisories
  issues [label]           list issues/PRs (default label: GSADV_LABEL or cve)
  new                     write a draft by hand in \$EDITOR from a template
  new <commit|url> [context] analyze a commit, issue or PR/MR with AI and create a draft
  show <id>               print advisory
  status <id>             show lifecycle, CVE and private report details
  credits <id>            manage credited people and roles in the TUI
  edit <id>               edit advisory in \$EDITOR
  review <id|commit|url> [context] review an advisory or source with AI, then edit
  comment <issue|PR URL> [text] edit a discussion comment, then confirm posting
  similar <id|commit|url> [context] find similar bugs using the selection as a template
  fix <REPORT.md> [context] ask the AI to fix the reported bug and commit it locally
  quickfix <REPORT.md> [context] review and apply the suggested patch without builds or tests
  resume <directory>       continue saved work without running the AI again
  recover <log|directory> [opts] turn a saved claude.jsonl into Markdown (partial replies)
  cve <id>                 GitHub: request CVE; GitLab: show CVE request instructions
  approve <id>            alias for cve
  draft <id>              accept a report or reopen as a draft
  publish <id>            publish the advisory
  close <id>               close the advisory/disclosure
  reopen <id>              reopen a closed advisory/disclosure
  invalid <id|commit|url> [reason] show its local tag, or mark invalid with a reason
  unmark <id|commit|url>  remove its local mark (invalid, important, wip, pin or ignore)
GitLab disclosure IDs use GL-<issue number>; publish/draft/credits are GitHub-only.
Environment:
  GSADV_PROVIDER  github or gitlab (default: detect from Git remote or source URL)
  GSADV_HOST      server hostname (custom hosts also need a provider)
  GSADV_REMOTE    Git remote to use instead of upstream/origin
  GSADV_ADVISORY_LABEL  GitLab disclosure label (default: security-advisory)
  GSADV_REPO   default repository (otherwise taken from the cwd checkout)
  GSADV_GREP   git log -E --grep (default: ##(crash|security|vuln|sandbox); empty: all commits)
  GSADV_LABEL  issues/PRs label (default: cve; empty: all labels; includes open and closed items)
  --label and --grep override these settings; use an empty value to disable a filter.
  Per-repository defaults: git config --local gsadv.label security; git config --local gsadv.grep fix
  Per-project settings: .gsadv.ini at the checkout root (key=value; press , in the TUI)
  GSADV_ANTFIND  directory scanned for REPORT.md files in the Reports tab (default: ANTFIND)
  GSADV_ATTIC    directory name skipped below it (default: Attic)
  GSADV_AI     agent command, prompt is piped to stdin (default: claude -p)
               progress goes to stderr; replies are saved for recovery
               e.g. "codex exec -", \'pmai --progress "\$(cat)"\', \'opencode run "\$(cat)"\''

fn issue_label(args []string) string {
	if args.len > 1 { return args[1] }
	return project_setting('label')
}

fn main() {
	mut args := os.args[1..].clone()
	for args.len > 0 && args[0] in ['-r', '--provider', '--host', '--remote', '--label', '--grep'] {
		if args.len < 2 { eprintln('missing value for ${args[0]}'); exit(1) }
		name := match args[0] {
			'-r' { 'GSADV_REPO' }
			'--provider' { 'GSADV_PROVIDER' }
			'--host' { 'GSADV_HOST' }
			'--label' { 'GSADV_LABEL' }
			'--grep' { 'GSADV_GREP' }
			else { 'GSADV_REMOTE' }
		}
		os.setenv(name, args[1], true)
		args = args[2..].clone()
	}
	if args.len > 0 && args[0] in ['-h', '--help', 'help'] {
		println(help)
		return
	}
	if args.len > 0 && args[0] in ['-v', '--version', 'version'] {
		println('gsadv ${version}')
		return
	}
	cmd := if args.len > 0 { args[0] } else { 'tui' }
	id := if args.len > 1 { args[1] } else { '' }
	ctx := if args.len > 2 { args[2..].join(' ') } else { '' }
	if cmd == 'recover' {
		cmd_recover(args[1..]) or {
			eprintln('error: ${err}')
			exit(1)
		}
		return
	}
	if cmd == 'resume' {
		if id == '' {
			eprintln('usage: gsadv resume <recovery-directory>')
			exit(1)
		}
		resume_edit(os.real_path(id), false) or {
			eprintln('error: ${err}')
			exit(1)
		}
		return
	}
	if cmd == 'tui' {
		tui(GitHub{}, issue_label(args))
		return
	}
	input := if cmd in ['new', 'review', 'comment', 'similar', 'invalid', 'unmark'] { id } else { '' }
	api := configured_repository(input) or {
		eprintln('cannot select repository: ${err}')
		exit(1)
	}
	if cmd !in ['ls', 'log', 'issues', 'new'] && id == '' {
		eprintln(help)
		exit(1)
	}
	if api.provider == 'gitlab' && cmd in ['draft', 'publish'] {
		eprintln('GitLab disclosure issues use close/reopen; manage confidentiality explicitly on GitLab. This does not publish a CVE.')
		exit(1)
	}
	match cmd {
		'ls' {
			marks := api.marks()!
			rows := api.advisories_with_releases(id)!
			println(marked_row(advisory_columns(999), '', 999))
			for r in rows {
				println(marked_row(row(r, 999), mark_symbol((marks[invalid_key(r[0])] or { Mark{} }).kind), 999))
			}
		}
		'log' {
			marks := api.marks()!
			advs := api.advisories('')!
			for c in commits()! {
				println(marked_row(crow(c, advs, 999), mark_symbol((marks[invalid_key(c[0])] or { Mark{} }).kind), 999))
			}
		}
		'issues' {
			marks := api.marks()!
			advs := api.advisories('')!
			for item in api.issues(issue_label(args))! {
				println(marked_row(irow(item, advs, 999), mark_symbol((marks[invalid_key(item[0])] or { Mark{} }).kind), 999))
			}
		}
		'invalid', 'unmark' {
			target := api.invalid_target(id) or {
				eprintln('error: ${err}')
				exit(1)
			}
			if cmd == 'invalid' {
				if ctx.trim_space() == '' {
					marks := api.invalid_marks()!
					reason := marks[target]
					println(if reason == '' { 'No local invalid tag for ${id}' } else { 'invalid (local): ${reason}' })
					return
				}
				api.mark_invalid(target, ctx) or {
					eprintln('error: ${err}')
					exit(1)
				}
				println('Marked ${id} invalid locally: ${ctx}')
			} else {
				api.unmark_invalid(target)!
				println('Removed local invalid tag from ${id}')
			}
		}
		'new' {
			cmd_new(api, id, ctx) or {
				eprintln('error: ${err}')
				exit(1)
			}
		}
		'show' {
			print(api.advisory(id)!)
		}
		'status' {
			println(api.status(id)!)
		}
		'credits' {
			credits_tui(api, id) or {
				eprintln('error: ${err}')
				exit(1)
			}
		}
		'edit' {
			cmd_edit(api, id) or {
				eprintln('error: ${err}')
				exit(1)
			}
		}
		'review' {
			if api.is_advisory(id) {
				cmd_review(api, id, ctx) or { eprintln('error: ${err}'); exit(1) }
			} else {
				cmd_source_review(api, id, ctx) or { eprintln('error: ${err}'); exit(1) }
			}
		}
		'comment' {
			cmd_comment(api, id, ctx) or {
				eprintln('error: ${err}')
				exit(1)
			}
		}
		'similar' {
			cmd_similar(api, id, ctx) or {
				eprintln('error: ${err}')
				exit(1)
			}
		}
		'fix', 'quickfix' {
			cmd_fix(api, id, ctx, cmd == 'quickfix') or {
				eprintln('error: ${err}')
				exit(1)
			}
		}
		'cve', 'approve' {
			println(api.request_cve(id)!)
		}
		'draft', 'publish', 'close', 'reopen' {
			if os.input('${cmd} ${id}? [y/N] ') == 'y' {
				state := match cmd {
					'draft' { 'draft' }
					'reopen' { if api.provider == 'gitlab' { 'opened' } else { 'draft' } }
					'publish' { 'published' }
					else { 'closed' }
				}
				api.set_state(id, state)!
			}
		}
		else {
			eprintln(help)
			exit(1)
		}
	}
}

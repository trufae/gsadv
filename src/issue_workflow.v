module main

import json2
import os

fn cmd_issue_workflow(api Repository, cmd string, input string, ctx string) ! {
	number := input != '' && input.bytes().all(it.is_digit())
	s := api.source(if number {
		api.url() + if api.provider == 'gitlab' { '/-/issues/' } else { '/issues/' } + input
	} else {
		input
	})!
	if s.kind != 'issues' { return error('${cmd} requires an issue URL or number') }
	evidence := api.source_text(s, false)!
	prompt := render(match cmd {
		'issue-fix' { prompt_issue_fix }
		'issue-review' { prompt_issue_review }
		else { prompt_issue_related }
	}, {
		'repo':     api.repo
		'cli':      api.cli()
		'project':  api.url()
		'url':      s.url
		'ctx':      ctx
		'evidence': evidence
	})
	resume_edit(start_edit(api, s.url, cmd, evidence, prompt)!, true)!
}

fn resume_issue_fix(dir string, session EditSession, run_ai bool, resume string) ! {
	if run_ai {
		api := repository_location(session.repo, session.provider, session.host)!
		verify_issue_checkout(api)!
		ask_ai(dir, false, true, '', '', resume) or { return ai_error(dir, err.msg()) }
	}
	path := os.join_path(dir, 'reply.txt')
	report := os.read_file(path)!
	if report.trim_space() == '' { return ai_error(dir, 'empty implementation summary') }
	println('Implementation summary saved in ${path}')
	view_text(report, .markdown)!
}

fn verify_issue_checkout(api Repository) ! {
	remotes := os.exec(['git', 'remote'])
	if remotes.exit_code == 0 {
		for name in remotes.output.split_into_lines() {
			remote := os.exec(['git', 'remote', 'get-url', '--', name])
			if remote.exit_code != 0 { continue }
			location := repository_location(remote.output.trim_space(), api.provider, '') or { continue }
			if location.host == api.host && location.repo.to_lower() == api.repo.to_lower() { return }
		}
	}
	return error('Run issue-fix in a checkout with a remote for ${api.url()}')
}

struct RelatedIssueComment {
	url string
	body string
}

struct RelatedIssues {
	summary string
	comments []RelatedIssueComment
}

fn resume_related_issues(dir string, session EditSession, run_ai bool, resume string) ! {
	api := repository_location(session.repo, session.provider, session.host)!
	plan_path := os.join_path(dir, 'related.json')
	if !os.is_file(plan_path) {
		if run_ai {
			ask_ai(dir, false, false, '', '', resume) or { return ai_error(dir, err.msg()) }
		}
		mut reply := os.read_file(os.join_path(dir, 'reply.txt'))!.trim_space()
		if reply.starts_with('```') && reply.ends_with('```') {
			reply = reply.all_after_first('\n').trim_string_right('```').trim_space()
		}
		plan := json2.decode[RelatedIssues](reply) or { return ai_error(dir, 'invalid related-issue reply: ${err}') }
		if plan.summary.trim_space() == '' { return ai_error(dir, 'related-issue reply has no summary') }
		mut urls := map[string]bool{}
		for draft in plan.comments {
			target := api.source(draft.url) or { return ai_error(dir, 'invalid comment target: ${err}') }
			if target.kind != 'issues' || draft.body.trim_space() == '' || target.url.to_lower() in urls {
				return ai_error(dir, 'invalid or duplicate issue comment for ${draft.url}')
			}
			urls[target.url.to_lower()] = true
		}
		os.write_file(plan_path, json2.encode(plan))!
	}
	plan := json2.decode[RelatedIssues](os.read_file(plan_path)!)!
	println(plan.summary)
	for i, draft in plan.comments {
		target := api.source(draft.url)!
		if target.kind != 'issues' { return error('invalid saved issue target ${draft.url}') }
		path := os.join_path(dir, 'comment-${i + 1}')
		os.mkdir_all(path, mode: 0o700)!
		child := EditSession{repo: session.repo, id: target.url, kind: 'comment', provider: session.provider, host: session.host}
		metadata := os.join_path(path, 'session.json')
		if !os.exists(metadata) {
			os.write_file(os.join_path(path, 'original.md'), draft.body)!
			os.write_file(metadata, json2.encode(child))!
		}
		println('\nDraft for ${target.url}')
		resume_comment(path, child, false, '')!
	}
}

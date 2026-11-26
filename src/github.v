module main

import os
import json2
import net.urllib
import time

struct GitHub {
	repo string
	provider string = 'github'
	host string = 'github.com'
}

const jq_text = '"# \\(.ghsa_id) \\(.state) \\(.cve_id // "no-cve") \\(.html_url)
summary: \\(.summary)
severity: \\(.severity // "")
cvss: \\(.cvss.vector_string // "")
cwe: \\([.cwes[]?.cwe_id] | join(", "))
credits: \\([.credits[]? | "\\(.login):\\(.type)"] | join(", "))
" + ([.vulnerabilities[]? | "package: \\(.package.name // "")
ecosystem: \\(.package.ecosystem)
affected: \\(.vulnerable_version_range // "")
patched: \\(.patched_versions // "")
"] | join("")) + "---\\n" + (.description // "")'

const jq_status = '"advisory: \\(.ghsa_id)
state: \\(.state)
cve: \\(.cve_id // "unassigned")
private report: \\(if .submission == null then "no" elif .submission.accepted then "accepted" else "not accepted" end)
created: \\(.created_at // "-")
updated: \\(.updated_at // "-")
published: \\(.published_at // "-")
closed: \\(.closed_at // "-")
withdrawn: \\(.withdrawn_at // "-")
private fork: \\(.private_fork.html_url // "-")
url: \\(.html_url)"'

const jq_source = '"# \\(.title)\n\nURL: \\(.html_url)\nAuthor: @\\(.user.login)\nState: \\(.state)\n" +
(if has("merged") then "Merged: \\(.merged)\nMerged at: \\(.merged_at // "-")\nMerge commit: \\(.merge_commit_sha // "-")\nBase: \\(.base.ref)\nHead: \\(.head.ref)\n" else "" end) +
"\n" + (.body // "")'

const jq_advisories = '.[] | [
  .ghsa_id, .state, .cve_id // "-", .severity // "-", .summary,
  ([.description // "" | scan("[0-9a-f]{10,40}")] | join(",")),
  ([.description // "" | scan("https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(?:issues|pull)/[0-9]+")] | join(",")),
  "",
  ([.vulnerabilities[]? | (.patched_versions // "" | gsub("^\\\\s+|\\\\s+$"; "")) |
    if . == "" then "unknown" else . end] | unique | join("; ")),
  ([.vulnerabilities[]? | (.package.name // "package") + ": " +
    (if (.vulnerable_version_range // "") == "" then "unknown" else .vulnerable_version_range end)] | join("; "))
] | @tsv'

fn (api GitHub) source_text(s Source, with_patch bool) !string {
	if s.kind == 'commit' {
		patch := api.patch('repos/${api.repo}/commits/${s.ref}')!
		return patch#[..200000]
	}
	endpoint := if s.kind == 'pull' { 'pulls' } else { 'issues' }
	mut text := api.request('repos/${api.repo}/${endpoint}/${s.ref}', '--jq', jq_source)!
	comments := api.request('--paginate', 'repos/${api.repo}/issues/${s.ref}/comments?per_page=100',
		'--jq', '.[] | "### @\\(.user.login)\n\\(.html_url)\n\n\\(.body // "")\n"')!
	text += '\n## Discussion\n${comments}'
	if s.kind == 'pull' && with_patch {
		patch := api.patch('repos/${api.repo}/pulls/${s.ref}')!
		text += '\nPR patch:\n${patch#[..200000]}'
	}
	return text
}

fn (api GitHub) patch(path string) !string {
	// Capture patches as evidence, preserving literal escape bytes in source fixtures.
	return api.request('--allow-escape-sequences', '-H', 'Accept: application/vnd.github.patch', path) or {
		// Older gh versions predate the flag and already return patches verbatim.
		if !err.msg().starts_with('unknown flag: --allow-escape-sequences') { return err }
		api.request('-H', 'Accept: application/vnd.github.patch', path)!
	}
}

fn (api GitHub) advisory(id string) !string {
	return api.request('repos/${api.repo}/security-advisories/${id}', '--jq', jq_text)!.replace('\r', '')
}

fn (api GitHub) list_advisories(state string) ![][]string {
	query := '?per_page=100' + if state in ['', 'all'] { '' } else { '&state=${state}' }
	out := api.request('--paginate', 'repos/${api.repo}/security-advisories${query}', '--jq',
		jq_advisories.replace('https://github[.]com/', 'https://' + api.host.replace('.', '[.]') + '/'))!
	mut rows := out.split_into_lines().filter(it != '').map(it.split('\t'))
	for mut row in rows {
		if row.len >= 5 && row[2] == '-' && api.cve_requested_at(row[0]) != '' {
			row[2] = 'requested*'
		}
	}
	return rows
}

fn (api GitHub) releases() !map[string]string {
	out := api.request('--paginate', 'repos/${api.repo}/releases?per_page=100', '--jq',
		'.[] | [.tag_name, (if .draft then "draft" elif .published_at == null then "unknown" elif .prerelease then "prerelease" else "released" end)] | @tsv')!
	mut releases := map[string]string{}
	for line in out.split_into_lines() {
		if line == '' { continue }
		fields := line.split('\t')
		if fields.len != 2 || fields[1] !in ['draft', 'unknown', 'prerelease', 'released'] {
			return error('invalid release data')
		}
		releases[fields[0]] = fields[1]
	}
	return releases
}

fn (api GitHub) status(id string) !string {
	text := api.request('repos/${api.repo}/security-advisories/${id}', '--jq', jq_status)!
	requested_at := api.cve_requested_at(id)
	cve := if requested_at != '' {
		'requested* (no CVE assigned)\nrequest accepted: ${requested_at} (recorded locally; current GitHub request status unavailable)'
	} else {
		'unassigned (request status unknown; GitHub REST does not expose it)'
	}
	return text.replace_once('\ncve: unassigned\n', '\ncve: ${cve}\n')
}

// GitHub exposes assigned IDs, but no pending-request status. Keep a receipt of
// successful requests, shared by the CLI and TUI, without treating it as live status.
fn (api GitHub) cve_request_path(id string) string {
	return Repository(api).state_path('cve-requests', id)
}

fn (api GitHub) cve_requested_at(id string) string {
	text := os.read_file(api.cve_request_path(id)) or { return '' }
	stamp := text.trim_space()
	time.parse_rfc3339(stamp) or { return '' }
	return stamp
}

fn (api GitHub) save_cve_request(id string) ! {
	path := api.cve_request_path(id)
	os.mkdir_all(os.dir(path), mode: 0o700)!
	os.write_file(path, time.utc().format_rfc3339() + '\n')!
}

fn (api GitHub) request_cve(id string) !string {
	cve := api.request('repos/${api.repo}/security-advisories/${id}', '--jq', '.cve_id // ""')!.trim_space()
	if cve != '' {
		return 'CVE already assigned: ${cve}'
	}
	api.request('--method', 'POST', 'repos/${api.repo}/security-advisories/${id}/cve')!
	api.save_cve_request(id) or {
		return 'CVE request accepted, but could not save the local request receipt: ${err}. Check with gsadv status ${id}'
	}
	return 'CVE request accepted; assignment is asynchronous. Check with gsadv status ${id}'
}

// The issues endpoint includes pull requests. Closed items may still need a CVE.
fn (api GitHub) issues_path(label string, state string) string {
	filter := if label == '' { '' } else { '&labels=${urllib.query_escape(label)}' }
	return 'repos/${api.repo}/issues?state=${state}&per_page=100${filter}'
}

const jq_issues = '.[] | [(.pull_request.html_url // .html_url), .number, (if .pull_request then "PR" else "issue" end), .state, .title, .comments] | @tsv'

fn (api GitHub) issues(label string) ![][]string {
	out := api.request('--paginate', api.issues_path(label, 'all'), '--jq', jq_issues)!
	return out.split_into_lines().filter(it != '').map(it.split('\t'))
}

fn (api GitHub) issue_page(query IssueQuery, page int) !([][]string, bool) {
	out := api.request('${api.issues_path(query.label, query.state)}&page=${page}', '--jq', jq_issues)!
	rows := out.split_into_lines().filter(it != '').map(it.split('\t'))
	return rows, rows.len == 100
}

struct AdvisoryCredits {
	credits []Credit
}

fn (api GitHub) credits(id string) ![]Credit {
	return json2.decode[[]Credit](api.request('repos/${api.repo}/security-advisories/${id}',
		'--jq', '.credits // []')!)
}

fn (api GitHub) update_credits(id string, credits []Credit) ! {
	api.send('PATCH', 'repos/${api.repo}/security-advisories/${id}',
		json2.encode(AdvisoryCredits{ credits: credits }), '.ghsa_id')!
}

fn (api GitHub) send(method string, path string, payload string, query string) !string {
	f := os.join_path(os.temp_dir(), 'gsadv-${os.getpid()}.json')
	os.write_file(f, payload)!
	defer {
		os.rm(f) or {}
	}
	return api.request('--method', method, path, '--input', f, '--jq', query)
}

fn (api GitHub) comment(s Source, body string) !string {
	return api.send('POST', 'repos/${api.repo}/issues/${s.ref}/comments',
		json2.encode({'body': body}), '.html_url')!.trim_space()
}

fn (api GitHub) set_state(id string, state string) ! {
	api.request('--method', 'PATCH', 'repos/${api.repo}/security-advisories/${id}', '-f', 'state=${state}')!
}

fn (api GitHub) create_advisory(a Adv) !string {
	return api.send('POST', 'repos/${api.repo}/security-advisories', json2.encode(a), '.ghsa_id')!.trim_space()
}

fn (api GitHub) write_advisory(id string, a Adv) ! {
	api.send('PATCH', 'repos/${api.repo}/security-advisories/${id}', json2.encode(a), '.ghsa_id')!
}

fn (api GitHub) request(args ...string) !string {
	r := os.exec(['gh', 'api', '--hostname', api.host, ...args])
	if r.exit_code != 0 { return error(r.output.trim_space()) }
	return r.output
}

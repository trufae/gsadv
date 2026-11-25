module main

fn (api Repository) states() []string {
	return if api.provider == 'gitlab' { ['all', 'opened', 'closed'] } else { states }
}

fn (api Repository) cli() string {
	return if api.provider == 'gitlab' { 'glab' } else { 'gh' }
}

fn (api Repository) is_advisory(input string) bool {
	return if api.provider == 'gitlab' { input.starts_with('GL-') } else { input.starts_with('GHSA-') }
}

fn (api Repository) actions(a []string) []string {
	if api.provider == 'github' { return advisory_actions(a) }
	if a.len < 5 { return []string{} }
	mut actions := ['c CVE request instructions']
	if a[1] == 'closed' { actions << 'd reopen issue' }
	if a[1] == 'opened' { actions << 'x close issue' }
	return actions
}

fn (api Repository) help_text() string {
	if api.provider == 'github' { return tui_help }
	return tui_help.all_before('States:')
		.replace('C: manage advisory credits (finder, reporter, fix developer and other roles)', 'Credits: use e to edit attribution in the disclosure text')
		.replace('c: request CVE; d: accept/reopen as draft; p: publish; x: close', 'c: CVE request instructions; d: reopen issue; x: close issue')
		.replace('advisories', 'disclosures').replace('advisory', 'disclosure').replace('PR', 'MR') +
		'States: opened, closed. Confidentiality is shown separately.\nClosing or reopening never changes confidentiality.\nCVE IDs are references in the issue text, not proof of assignment or publication.\nGitLab CVE requests use a separate issue; c shows the instructions.\nPublishing and draft transitions are GitHub-only.'
}

fn (api Repository) advisories(state string) ![][]string {
	if state != '' && state !in api.states() { return error('invalid state: ${state}; choose ${api.states().join(', ')}') }
	return api.list_advisories(state)
}

// A single paginated release lookup serves the whole list. A release failure
// must not hide advisories or turn missing evidence into "no release".
fn (api Repository) advisories_with_releases(state string) ![][]string {
	mut rows := api.advisories(state)!
	mut failure := ''
	mut releases := map[string]string{}
	if rows.any(it.len > 8 && it[8] !in ['', 'unknown']) {
		releases = api.releases() or {
			failure = if err.msg() == '' { 'release request failed' } else { err.msg() }
			map[string]string{}
		}
	}
	for mut row in rows {
		if row.len < 5 { continue }
		for row.len < 10 { row << '' }
		if row[8] == '' { row[8] = 'unknown' }
		if row[9] == '' { row[9] = 'unknown' }
		released, detail := fixed_release_summary(row[8], releases, failure)
		row << released
		row << detail
	}
	return rows
}

fn (api Repository) update_advisory(id string, a Adv) ! {
	api.write_advisory(id, a)!
	text := api.advisory(id) or { return error('Update accepted, but reloading ${id} failed: ${err}') }
	saved := parse(text) or { return error('Update accepted, but the reloaded advisory is invalid: ${err}') }
	fields := advisory_changes(a, saved)
	if fields.len > 0 { return error('Update accepted, but the reloaded advisory differs in: ${fields.join(', ')}') }
}

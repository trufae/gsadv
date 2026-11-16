module main

// Advisory row fields: id, state, CVE, severity, summary, commits, URLs,
// visibility, patched versions, affected ranges, release state, release detail.
// Match recorded versions to repository releases, never infer a fix from an
// arbitrary commit hash in the description or from a local tag alone.
fn fixed_release_state(patched string, releases map[string]string, available bool) string {
	value := patched.trim_space()
	if !available || value in ['', '-', 'unknown'] { return 'unknown' }
	if value in releases { return releases[value] }
	number := if value.starts_with('v') || value.starts_with('V') { value[1..] } else { value }
	// Ecosystem-specific ranges and prose need review, not a guessed comparison.
	if number == '' || !number[0].is_digit()
		|| !number.bytes().all(it.is_alnum() || it in [`.`, `-`, `_`, `+`]) {
		return 'unknown'
	}
	for tag in [number, 'v' + number, 'V' + number] {
		if tag in releases { return releases[tag] }
	}
	return 'no release'
}

fn fixed_release_summary(versions string, releases map[string]string, failure string) (string, string) {
	mut statuses := []string{}
	mut details := []string{}
	for patched in versions.split('; ') {
		state := fixed_release_state(patched, releases, failure == '')
		if state !in statuses { statuses << state }
		detail := '${patched} (${state})'
		if detail !in details { details << detail }
	}
	return if statuses.len == 1 { statuses[0] } else { 'mixed' }, details.join('; ') +
		if failure == '' { '' } else { ' | release lookup failed: ' + failure.replace('\n', ' ') }
}

fn fixed_in(a []string) string {
	return if a.len > 8 && a[8] != '' { a[8] } else { 'unknown' }
}

fn release_state(a []string) string {
	return if a.len > 10 { a[10] } else { 'unknown' }
}

fn release_hint(a []string) string {
	detail := if a.len > 11 { a[11] } else { fixed_in(a) }
	affected := if a.len > 9 && a[9] != '' { a[9] } else { 'unknown' }
	return 'Fixed in: ${detail} | Affected: ${affected}'
}

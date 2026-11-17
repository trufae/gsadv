module main

import term

enum TuiLoadKind {
	repository
	advisories
	commits
	issues
	git_status
}

struct TuiLoad {
	kind TuiLoadKind
	text string
	error string
	repository Repository = GitHub{}
	more bool
mut:
	rows [][]string
}

// Workers own their results; only the input loop changes the displayed snapshot.
fn tui_load(api Repository, label string, kind TuiLoadKind, page int, results chan TuiLoad) {
	mut rows := [][]string{}
	mut more := false
	mut text := ''
	mut failure := ''
	mut repository := api
	match kind {
		.repository {
			repository = configured_repository('') or { failure = err.msg(); GitHub{} }
			text = repository.repo
			if text == '' && failure == '' { failure = 'cannot find repository' }
		}
		.advisories { rows = api.advisories_with_releases('') or { failure = err.msg(); [][]string{} } }
		.commits { rows = commits() or { failure = err.msg(); [][]string{} } }
		.issues { rows, more = api.issue_page(label, page) or { failure = err.msg(); [][]string{}, false } }
		.git_status { text = local_git_status() }
	}
	results <- TuiLoad{kind: kind, rows: rows, text: text, error: failure, repository: repository, more: more}
}

struct TuiLoader {
	results chan TuiLoad = chan TuiLoad{cap: 5}
mut:
	pending []bool = []bool{len: 5}
	again []bool = []bool{len: 5}
	issue_page int = 1
	issue_rows [][]string
}

// Coalesce repeated reloads. A workflow may require a fresh snapshot after an
// already running request; discard that old result before starting its successor.
fn (mut loader TuiLoader) request(api Repository, label string, kind TuiLoadKind, fresh bool) {
	i := int(kind)
	if loader.pending[i] {
		loader.again[i] = loader.again[i] || fresh
		return
	}
	loader.pending[i] = true
	if kind == .issues {
		loader.issue_page = 1
		loader.issue_rows = [][]string{}
	}
	spawn tui_load(api, label, kind, 1, loader.results)
}

fn (mut loader TuiLoader) poll(api Repository, label string) ?TuiLoad {
	for {
		mut result := TuiLoad{}
		if loader.results.try_pop(mut result) != .success { return none }
		i := int(result.kind)
		loader.pending[i] = false
		if loader.again[i] {
			loader.again[i] = false
			loader.request(api, label, result.kind, false)
			continue
		}
		if result.kind == .issues && result.error == '' {
			// Schedule one page at a time so new labels supersede a download
			// without waiting for the rest of the repository's history.
			loader.issue_rows << result.rows
			result.rows = loader.issue_rows.clone()
			if result.more {
				loader.pending[i] = true
				loader.issue_page++
				spawn tui_load(api, label, .issues, loader.issue_page, loader.results)
			}
		}
		return result
	}
	return none
}

struct TuiActionResult {
	id string
	key string
	message string
}

fn tui_action(api Repository, k string, id string, results chan TuiActionResult) {
	message := act(k, api, id) or { 'error: ' + err.msg().replace('\n', ' ') }
	results <- TuiActionResult{id, k, message}
}

fn tui_status_load(api Repository, id string, cve bool, results chan string) {
	results <- if cve { api.request_cve(id) or { 'error: ${err}' } } else { api.status(id) or { 'error: ${err}' } }
}

fn tui_details(api Repository, id string, cve bool, detail string) {
	results := chan string{cap: 1}
	spawn tui_status_load(api, id, cve, results)
	mut screen := TuiScreen{}
	for {
		mut text := ''
		if results.try_pop(mut text) == .success {
			tui_dialog(text + if detail == '' { '' } else { '\n\n' + detail })
			return
		}
		w, h := terminal_size()
		screen.draw(['Loading status for ${id}...', 'Esc/Ctrl+C/q: back'], w, h)
		if poll_key() in ['\x1b', '\x03', 'q', '\n', '\r'] { return }
	}
}

struct TuiRow {
	normal string
	selected string
}

fn (api Repository) tui_states(view int) []string {
	if view == 0 { return api.states() }
	if view == 1 { return ['all'] }
	if api.provider == 'github' { return ['all', 'open', 'closed'] }
	return if view == 3 { ['all', 'opened', 'closed', 'merged'] } else { ['all', 'opened', 'closed'] }
}

// Search/link work is tied to data changes. Row formatting is lazy and cached at
// the current width, including the selected variant, so movement only paints it.
struct TuiList {
mut:
	links []int
	search []string
	invalid []string
	matches []int
	visible []int
	formatted map[int]TuiRow
	width int
	query string
	state string
	state_column int
	filtered bool
}

fn (mut list TuiList) rebuild(entries [][]string, advs [][]string, links AdvisoryLinks, view int) {
	list.state_column = if view >= 2 { 3 } else { 1 }
	list.links = []int{len: entries.len, init: -1}
	list.search = []string{len: entries.len}
	list.invalid = []string{len: entries.len}
	for i, entry in entries {
		linked := if view == 0 { i } else if entry.len > 0 { links.find(entry[0]) } else { -1 }
		list.links[i] = linked
		list.search[i] = (entry.join(' ') + if view != 0 && linked >= 0 { ' ' + advs[linked][0] } else { '' }).to_lower()
	}
	list.formatted.clear()
	list.filtered = false
}

fn (mut list TuiList) mark_invalid(entries [][]string, marks map[string]string) {
	for i, entry in entries {
		if entry.len == 0 { continue }
		reason := marks[invalid_key(entry[0])]
		list.invalid[i] = reason
		if reason != '' { list.search[i] += ' invalid ' + reason.to_lower() }
	}
	list.formatted.clear()
	list.filtered = false
}

fn (mut list TuiList) filter(entries [][]string, query string, state string) {
	if list.filtered && list.query == query && list.state == state { return }
	list.query, list.state = query, state
	list.matches = []int{}
	list.visible = []int{}
	needle := query.to_lower()
	for i, text in list.search {
		if needle == '' || text.contains(needle) {
			list.matches << i
			if state == 'all' || (entries[i].len > list.state_column && entries[i][list.state_column] == state) { list.visible << i }
		}
	}
	list.filtered = true
}

fn (mut list TuiList) line(index int, entries [][]string, advs [][]string, view int, width int, selected bool) string {
	if list.width != width {
		list.formatted.clear()
		list.width = width
	}
	if index !in list.formatted {
		linked := list.links[index]
		a := if linked >= 0 { advs[linked] } else { []string{} }
		line := match view {
			0 { row(entries[index], width) }
			1 { commit_row(entries[index], a, width) }
			else { issue_row(entries[index], a, width) }
		}
		normal := marked_row(line, list.invalid[index], width)
		list.formatted[index] = TuiRow{normal, term.inverse(term.strip_ansi(normal))}
	}
	line := list.formatted[index]
	return if selected { line.selected } else { line.normal }
}

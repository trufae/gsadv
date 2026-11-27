module main

import os
import term
import time

enum TuiLoadKind {
	repository
	advisories
	commits
	git_status
	reports
	issue_label
	report_states
}

struct TuiLoad {
	kind TuiLoadKind
	text string
	error string
	repository Repository = GitHub{}
	rows [][]string
	partial bool
	dirs int
	report_updates map[int][]string
	report_revision int
}

// Workers own their results; only the input loop changes the displayed snapshot.
fn tui_load(api Repository, kind TuiLoadKind, results chan TuiLoad) {
	mut rows := [][]string{}
	mut text := ''
	mut failure := ''
	mut repository := api
	match kind {
		.repository {
			repository = configured_repository('') or { failure = err.msg(); GitHub{} }
			if repository.repo == '' && failure == '' { failure = 'cannot find repository' }
		}
		.advisories { rows = api.advisories_with_releases('') or { failure = err.msg(); [][]string{} } }
		.commits {
			text = commit_grep()
			rows = matching_commits(text) or { failure = err.msg(); [][]string{} }
		}
		.git_status { text = local_git_status() }
		.reports {
			text = reports_base()
			attic := project_setting('attic')
			dir := text
			progress := fn [dir, results] (dirs int, batch [][]string) bool {
				return results.try_push(TuiLoad{kind: .reports, text: dir, rows: batch, partial: true, dirs: dirs}) == .success
			}
			progress(0, [])
			rows = find_reports(dir, attic, progress)
		}
		.issue_label { text = project_setting('label') }
		.report_states { return }
	}
	results <- TuiLoad{kind: kind, rows: rows, text: text, error: failure, repository: repository}
}

fn tui_load_report_states(rows [][]string, revision int, results chan TuiLoad) {
	mut updates := map[int][]string{}
	for i, entry in rows {
		state := report_state(entry[0])
		if report_offloaded(entry) && !report_file_offloaded(entry[0]) {
			if text := os.read_file(entry[0]) {
				mut updated := report_with_contents(entry, text)
				updated[9] = state
				updates[i] = updated
				continue
			}
		}
		if state != entry[9] {
			mut updated := entry.clone()
			updated[9] = state
			updates[i] = updated
		}
	}
	results <- TuiLoad{kind: .report_states, report_updates: updates, report_revision: revision}
}

const tui_load_count = int(TuiLoadKind.report_states) + 1

struct TuiLoader {
	results chan TuiLoad = chan TuiLoad{cap: tui_load_count}
mut:
	pending []bool = []bool{len: tui_load_count}
	again []bool = []bool{len: tui_load_count}
	started []time.Time = []time.Time{len: tui_load_count}
}

// Coalesce repeated reloads. A workflow may require a fresh snapshot after an
// already running request; discard that old result before starting its successor.
fn (mut loader TuiLoader) request(api Repository, kind TuiLoadKind, fresh bool) {
	i := int(kind)
	if loader.pending[i] {
		loader.again[i] = loader.again[i] || fresh
		return
	}
	loader.pending[i] = true
	loader.started[i] = time.now()
	spawn tui_load(api, kind, loader.results)
}

fn (loader TuiLoader) running(kind TuiLoadKind) bool {
	return loader.pending[int(kind)]
}

fn (loader TuiLoader) seconds(kind TuiLoadKind) i64 {
	return time.since(loader.started[int(kind)]).milliseconds() / 1000
}

fn (mut loader TuiLoader) request_report_states(rows [][]string, revision int) {
	i := int(TuiLoadKind.report_states)
	if loader.pending[i] || rows.len == 0 { return }
	loader.pending[i] = true
	spawn tui_load_report_states(rows.clone(), revision, loader.results)
}

fn (mut loader TuiLoader) poll(api Repository) ?TuiLoad {
	for {
		mut result := TuiLoad{}
		if loader.results.try_pop(mut result) != .success { return none }
		i := int(result.kind)
		if result.partial {
			if loader.again[i] { continue }
			return result
		}
		loader.pending[i] = false
		if loader.again[i] {
			loader.again[i] = false
			loader.request(api, result.kind, false)
			continue
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

struct TuiPreviewResult {
	text string
	vf ViewFormat
	err string
}

struct TuiPreview {
	ref string
	title string
	result chan TuiPreviewResult
mut:
	doc DocumentView
}

fn start_preview(api Repository, view int, entry []string) ?TuiPreview {
	min_fields := match view {
		0 { 5 }
		4 { 9 }
		else { 3 }
	}
	if entry.len < min_fields || entry[0] == '' { return none }
	ref := entry[0]
	title := if view == 4 { entry[3] } else { ref }
	result := chan TuiPreviewResult{cap: 1}
	mut preview := TuiPreview{ref: ref, title: title, result: result}
	preview.doc.set_text(if view == 4 && report_offloaded(entry) { 'Downloading report...' } else { 'Loading preview...' }, .plain, false)
	spawn load_preview(api, view, ref, result)
	return preview
}

fn tui_download_report(api Repository, entry []string) ![]string {
	results := chan TuiPreviewResult{cap: 1}
	spawn load_preview(api, 4, entry[0], results)
	mut screen := TuiScreen{}
	for {
		mut result := TuiPreviewResult{}
		if results.try_pop(mut result) == .success {
			if result.err != '' { return error(result.err.replace('\n', ' ')) }
			return report_with_contents(entry, result.text)
		}
		w, h := terminal_size()
		screen.draw(['Downloading ${entry[3]}...', 'Esc/Ctrl+C/q: cancel'], w, h)
		if poll_key() in ['\x1b', '\x03', 'q'] { return error('Report download cancelled') }
	}
	return error('Report download cancelled')
}

fn load_preview(api Repository, view int, ref string, result chan TuiPreviewResult) {
	text, vf := read_preview(api, view, ref) or {
		result <- TuiPreviewResult{err: err.msg()}
		return
	}
	result <- TuiPreviewResult{text: text, vf: vf}
}

fn read_preview(api Repository, view int, ref string) !(string, ViewFormat) {
	match view {
		0 { return api.advisory(ref)!, .advisory }
		1 {
			show := os.exec(['git', '--no-pager', 'show', '--no-color', ref, '--'])
			if show.exit_code != 0 {
				msg := show.output.trim_space()
				return error(if msg == '' { 'Could not read commit ${ref}' } else { msg })
			}
			return show.output, .plain
		}
		4 { return os.read_file(ref)!, .markdown }
		else { return api.source_text(api.source(ref)!, false)!, .markdown }
	}
}

fn (mut preview TuiPreview) poll() {
	mut result := TuiPreviewResult{}
	if preview.result.try_pop(mut result) != .success { return }
	if result.err != '' {
		preview.doc.set_text('Could not load preview\n${result.err}', .plain, false)
	} else {
		preview.doc.set_text(result.text, result.vf, true)
	}
}

struct TuiRow {
	normal string
	selected string
}

fn (api Repository) tui_states(view int) []string {
	if view == 0 { return api.states() }
	if view == 1 { return ['all'] }
	if view == 4 { return report_states }
	if api.provider == 'github' { return ['open', 'closed', 'all'] }
	return if view == 3 { ['opened', 'closed', 'merged', 'all'] } else { ['opened', 'closed', 'all'] }
}

// Search/link work is tied to data changes. Row formatting is lazy and cached at
// the current width, including the selected variant, so movement only paints it.
struct TuiList {
mut:
	links []int
	search []string
	marks []Mark
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
	list.state_column = if view in [2, 3] { 3 } else { 1 }
	list.links = []int{len: entries.len, init: -1}
	list.search = []string{len: entries.len}
	list.marks = []Mark{len: entries.len}
	for i, entry in entries {
		linked := match view {
			0 { i }
			1 { links.find(entry[0] or { '' }, entry[4] or { '' }) }
			4 { -1 }
			else { links.find(entry[0] or { '' }) }
		}
		list.links[i] = linked
		list.search[i] = (entry.join(' ') + if view != 0 && linked >= 0 { ' ' + advs[linked][0] } else { '' }).to_lower()
	}
	list.formatted.clear()
	list.filtered = false
}

fn mark_key(entry []string, view int) string {
	if entry.len == 0 || (view == 4 && report_offloaded(entry)) { return '' }
	return if view == 4 && entry.len >= 9 { invalid_key('report:' + entry[3]) } else { invalid_key(entry[0]) }
}

fn (mut list TuiList) mark(entries [][]string, marks map[string]Mark, view int) {
	for i, entry in entries {
		mark := marks[mark_key(entry, view)] or { Mark{} }
		list.marks[i] = mark
		if mark.kind != '' { list.search[i] += ' ${mark.kind} ${mark.reason.to_lower()}' }
	}
	list.formatted.clear()
	list.filtered = false
}

fn (mut list TuiList) filter(entries [][]string, query string, state string) {
	if list.filtered && list.query == query && list.state == state { return }
	list.query, list.state = query, state
	list.matches = []int{}
	mut pinned, mut rest, mut ignored := []int{}, []int{}, []int{}
	needle := query.to_lower()
	for i, text in list.search {
		if needle == '' || text.contains(needle) {
			list.matches << i
			if state == 'all' || (entries[i].len > list.state_column && entries[i][list.state_column] == state) {
				// Pinned items lead the list and ignored items trail it.
				match list.marks[i].kind {
					'pin' { pinned << i }
					'ignore' { ignored << i }
					else { rest << i }
				}
			}
		}
	}
	list.visible = []int{cap: pinned.len + rest.len + ignored.len}
	list.visible << pinned
	list.visible << rest
	list.visible << ignored
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
		kind := list.marks[index].kind
		line := match view {
			0 { row(entries[index], width) }
			1 { commit_row(entries[index], a, width) }
			4 { report_row(entries[index], width, kind == 'invalid') }
			else { issue_row(entries[index], a, width) }
		}
		normal := marked_row(if kind == 'ignore' { term.dim(term.strip_ansi(line)) } else { line }, mark_symbol(kind), width)
		list.formatted[index] = TuiRow{normal, term.inverse(term.strip_ansi(normal))}
	}
	line := list.formatted[index]
	return if selected { line.selected } else { line.normal }
}

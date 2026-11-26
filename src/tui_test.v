module main

import encoding.utf8
import os
import term

fn test_clip_terminal_cells_and_styles() {
	assert clip_line('ab界cd', 4) == 'ab界'
	assert clip_line('ab界cd', 3) == 'ab'
	assert clip_line('🟠 fix', 2) == '🟠'
	assert clip_line('🟠 fix', 1) == ''
	assert clip_line('e\u0301x', 1) == 'e\u0301'
	assert clip_line('👩🏽‍💻x', 2) == '👩🏽‍💻'
	assert clip_line('🇯🇵x', 2) == '🇯🇵'
	assert clip_line('❤️x', 2) == '❤️'
	assert clip_line('text', 0) == ''
	assert clip_line('text', -1) == ''
	assert clip_line('\x1b[31m界xx\x1b[0m', 3) == '\x1b[31m界x\x1b[0m'
	assert clip_line('one\n\t\rtwo\x1b[2J\x1b[H!', 40) == 'one   two!'
	assert clip_line('a\x1b]0;title\x07b\x1b]8;;url\x1b\\c', 20) == 'abc'
	assert clip_line('a\x1b[', 20) == 'a'
}

fn test_rows_fit_every_width() {
	title := 'Fix 界 e\u0301 👩🏽‍💻 🟠 '.repeat(20)
	a := ['GHSA-abcd-efgh-ijkl', 'published', 'CVE-2026-123456789', 'critical', title, 'abcdef0123', '', '',
		'1.2.3; 界 e\u0301 👩🏽‍💻 🟠', 'parser: < 1.2.3', 'mixed', '1.2.3 (released); unknown']
	for w in 1 .. 201 {
		for line in [row(a, w), crow(['abcdef0123456789', '2026-11-09', title], [a], w),
			irow(['url', '123456789', 'issue', 'closed', title], [a], w),
			irow(['url', '7', 'PR', 'open', title, '12345'], [a], w),
			row(['error:', title], w), crow(['error:', title], [a], w),
			irow(['error:', title], [a], w)] {
			plain := term.strip_ansi(line)
			assert utf8.validate_str(plain)
			mut width := 0
			for g in plain.graphemes() { width += cell_width(g) }
			assert width <= line_width(w), '${w}: ${plain}'
			assert !plain.contains('\n')
		}
	}
	assert row(a, 30).starts_with('Fix')
	assert crow(['short', 'date', title], [a], 80).contains('short')
	assert irow(['url', '7', 'PR', 'open', 'Fix', '3'], [][]string{}, 100).starts_with('#7       PR    open           3 ')
	assert irow(['url', '7', 'PR', 'open', 'Fix', '3'], [][]string{}, 60) == '#7 PR open 3 Fix'
}

fn test_small_layouts_and_scroll_limits() {
	for h in 1 .. 60 {
		for dimensions in [[2, 3], [3, 3], [3, 4], [1, 1]] {
			headers, footers := dimensions[0], dimensions[1]
			layout := tui_layout(h, headers, footers)
			assert layout.page >= 1
			assert layout.head + layout.page + layout.foot == h
			frame := list_frame(layout, []string{len: headers, init: 'header'}, ['selected'],
				[]string{len: footers, init: 'footer'})
			assert frame.len == h
			assert frame[layout.head] == 'selected'
			for count in [0, 1, 4, 100] {
				for sel in 0 .. int_max(1, count) {
					for old in [-20, 0, 50, 1000] {
						top := list_top(old, sel, count, layout.page)
						assert top >= 0 && top <= int_max(0, count - layout.page)
						assert top <= sel && sel < top + layout.page
					}
				}
			}
		}
	}
	assert list_top(99, 99, 100, 10) == 90
	assert list_top(90, 0, 100, 10) == 0
	assert list_top(90, 99, 100, 200) == 0
}

fn test_tabs_keep_all_views_until_the_compact_row_no_longer_fits() {
	tabs := ['advisories 12 (all)', 'commits 34', 'issues 5 (label: cve)', 'PRs 7 (label: cve)']
	assert tui_tabs(tabs, 0, 120) == term.inverse('[advisories 12 (all)]') + ' | commits 34 | issues 5 (label: cve) | PRs 7 (label: cve)'
	assert tui_tabs(tabs, 1, 40) == 'advisories | ' + term.inverse('[commits 34]') + ' | issues | PRs'
	assert tui_tabs(tabs, 2, 60) == 'advisories | commits | ' + term.inverse('[issues 5 (label: cve)]') + ' | PRs'
	assert tui_tabs(tabs, 1, 38) == 'advisories | ' + term.inverse('[commits]') + ' | issues | PRs'
	assert tui_tabs(tabs, 2, 40) == 'advisories | commits | ' + term.inverse('[issues]') + ' | PRs'
	assert tui_tabs(tabs, 3, 40) == 'advisories | commits | issues | ' + term.inverse('[PRs]')
	assert tui_tabs(tabs, 1, 20) == term.inverse('[commits 34]')
	for view in 0 .. tabs.len {
		for width in 1 .. 100 {
			line := term.strip_ansi(tui_tabs(tabs, view, width))
			assert clip_line(line, width) == line
			if width >= 20 { assert line.contains('[' + tabs[view].all_before(' ')) }
		}
	}
}

fn test_render_updates_only_changed_rows_without_scrolling() {
	mut screen := TuiScreen{}
	first := screen.render(['one', 'two'], 10, 3)
	assert !first.contains('\n') && !first.contains('\r') && !first.contains('\x1b[2J')
	assert screen.render(['one', 'two'], 10, 3) == ''
	changed := screen.render(['one', 'short'], 10, 3)
	assert changed.contains('\x1b[2;1H') && changed.contains('short\x1b[0m\x1b[K')
	assert !changed.contains('\x1b[1;1H') && !changed.contains('\x1b[3;1H')
	shrunk := screen.render(['界', 'hidden'], 1, 1)
	assert screen.lines == ['']
	assert shrunk.contains('\x1b[1;1H') && !shrunk.contains('\x1b[2;1H')
	assert shrunk.starts_with('\x1b[?7l') && shrunk.ends_with('\x1b[?7h')
	screen.width = 0
	assert screen.render([''], 1, 1) != ''
}

fn test_wrapped_dialogs_and_input_tails() {
	assert wrap_text('abcd\n界x\n', 2) == ['ab', 'cd', '界', 'x', '']
	assert wrap_text('界x', 1) == ['?', 'x']
	assert input_line('Username: ', 'abcdefghijkl', 8) == 'Userijkl'
	assert input_line('Filter: ', 'abc界', 1) == ''
	assert input_line('Filter: ', 'abc界', 4) == 'Fi界'
}

fn test_list_cache_refreshes_links_filters_and_row_width() {
	entries := [['abcdef1234567890', '2026-11-09', 'Fix bounds check 界'],
		['1234567890abcdef', '2026-11-08', 'Other fix']]
	advs := [['GHSA-one', 'draft', '-', 'high', 'Bounds check', 'abcdef1234', '']]
	mut list := TuiList{}
	list.rebuild(entries, [], AdvisoryLinks{}, 1)
	list.filter(entries, 'GHSA-ONE', 'all')
	assert list.visible == []int{}
	assert !list.line(0, entries, [], 1, 120, false).contains('GHSA-one')
	// Advisories can arrive after commits; both search and formatted links update.
	list.rebuild(entries, advs, advisory_links(advs), 1)
	list.filter(entries, 'GHSA-ONE', 'all')
	assert list.visible == [0]
	assert list.line(0, entries, advs, 1, 120, false).contains('GHSA-one')
	assert list.line(0, entries, advs, 1, 30, false) == '  Fix bounds check 界'
	assert term.strip_ansi(list.line(0, entries, advs, 1, 30, true)) == '  Fix bounds check 界'
	list.filter(entries, '', 'all')
	assert list.visible == [0, 1]
	// A refresh removing a link cannot retain its text filter or severity.
	list.rebuild(entries, [], AdvisoryLinks{}, 1)
	list.filter(entries, 'ghsa-one', 'all')
	assert list.visible == []int{}
	assert !list.line(0, entries, [], 1, 120, false).contains('GHSA-one')
}

fn test_state_filters_follow_the_provider_and_view() {
	github := Repository(GitHub{})
	gitlab := Repository(GitLab{})
	assert github.tui_states(0) == github.states()
	assert gitlab.tui_states(0) == gitlab.states()
	for api in [github, gitlab] {
		assert api.tui_states(1) == ['all']
	}
	assert github.tui_states(2) == ['all', 'open', 'closed']
	assert github.tui_states(3) == ['all', 'open', 'closed']
	assert gitlab.tui_states(2) == ['all', 'opened', 'closed']
	assert gitlab.tui_states(3) == ['all', 'opened', 'closed', 'merged']
}

fn test_issue_state_filter_uses_state_column_and_combines_with_text() {
	for view in [2, 3] {
		entries := [['url/1', '1', 'issue', 'open', 'Parser bounds'],
			['url/2', '2', 'issue', 'closed', 'Reopen parser'],
			['url/3', '3', 'PR', 'open', 'Other fix'], ['error:', 'unavailable']]
		mut list := TuiList{}
		list.rebuild(entries, [], AdvisoryLinks{}, view)
		list.filter(entries, '', 'open')
		assert list.visible == [0, 2]
		list.filter(entries, 'PARSER', 'open')
		assert list.visible == [0]
		list.filter(entries, 'parser', 'closed')
		assert list.visible == [1]
		list.filter(entries, 'parser', 'all')
		assert list.visible == [0, 1]
		list.filter(entries, '', 'all')
		assert list.visible == [0, 1, 2, 3]
	}
}

fn test_gitlab_merge_request_state_filter_refreshes_with_new_rows() {
	mut entries := [['url/1', '1', 'MR', 'opened', 'Fix parser'],
		['url/2', '2', 'MR', 'merged', 'Fix parser'],
		['url/3', '3', 'MR', 'closed', 'Fix parser']]
	mut list := TuiList{}
	list.rebuild(entries, [], AdvisoryLinks{}, 3)
	list.filter(entries, '', 'opened')
	assert list.visible == [0]
	list.filter(entries, '', 'merged')
	assert list.visible == [1]
	entries << ['url/4', '4', 'MR', 'merged', 'Another fix']
	list.rebuild(entries, [], AdvisoryLinks{}, 3)
	list.filter(entries, '', 'merged')
	assert list.visible == [1, 3]
	// Advisory state filtering still uses the advisory's second column.
	advs := [['GHSA-one', 'draft', '-', 'high', 'Parser'],
		['GHSA-two', 'closed', '-', 'high', 'Other fix']]
	list.rebuild(advs, advs, advisory_links(advs), 0)
	list.filter(advs, '', 'draft')
	assert list.visible == [0]
}

fn test_selection_movement_only_paints_two_rows() {
	mut screen := TuiScreen{}
	mut lines := []string{len: 30, init: 'Row ${index} 界 e\u0301'}
	lines[4] = term.inverse(lines[4])
	screen.render(lines, 100, 30)
	lines[4] = term.strip_ansi(lines[4])
	lines[5] = term.inverse(lines[5])
	paint := screen.render(lines, 100, 30)
	assert paint.count(';1H') == 2
	assert paint.contains('\x1b[5;1H') && paint.contains('\x1b[6;1H')
	assert screen.render(lines, 100, 30) == ''
	// Scrolling moves already clipped rows; dropped content must leave the cache.
	lines = lines[1..].clone()
	lines << 'new bottom row'
	assert screen.render(lines, 100, 30).count(';1H') == 30
	assert 'Row 0 界 e\u0301' !in screen.clipped
	assert screen.clipped.len == 30
	assert screen.render(lines, 8, 30) != ''
	assert screen.lines[29] == 'new bot'
}

fn test_resume_dir_unquotes_resume_hint() {
	dir := "/tmp/gsadv-x/it's here"
	assert resume_dir('invalid Claude event\nResume without AI: gsadv resume ${os.quoted_path(dir)}') == dir
	assert resume_dir('no hint') == ''
}

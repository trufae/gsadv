module main

import os
import term

fn test_invalid_marks_persist_and_are_scoped_to_host_repository_and_item() ! {
	dir := os.join_path(os.temp_dir(), 'gsadv-invalid-test-${os.getpid()}')
	old_state := os.getenv_opt('XDG_STATE_HOME')
	old_host := os.getenv_opt('GH_HOST')
	os.setenv('XDG_STATE_HOME', dir, true)
	os.setenv('GH_HOST', 'github.com', true)
	defer {
		if value := old_state { os.setenv('XDG_STATE_HOME', value, true) } else { os.unsetenv('XDG_STATE_HOME') }
		if value := old_host { os.setenv('GH_HOST', value, true) } else { os.unsetenv('GH_HOST') }
		os.rmdir_all(dir) or {}
	}
	api := Repository(GitHub{repo: 'owner/repo'})
	assert api.invalid_marks()!.len == 0
	assert !os.exists(dir)
	target := invalid_target(api.repo, 'GHSA-abcd-efgh-ijkl')!
	api.mark_invalid(target, ' No tagged release shipped vulnerable code.\nIntroduced and fixed after v1. ' )!
	assert Repository(GitHub{repo: 'OWNER/REPO'}).invalid_marks()![target] == 'No tagged release shipped vulnerable code.\nIntroduced and fixed after v1.'
	assert Repository(GitHub{repo: 'other/repo'}).invalid_marks()!.len == 0
	os.setenv('GH_HOST', 'enterprise.example', true)
	assert Repository(GitHub{repo: api.repo, host: 'enterprise.example'}).invalid_marks()!.len == 0
	os.setenv('GH_HOST', 'github.com', true)
	issue := 'https://github.com/owner/repo/issues/1'
	api.mark_invalid(issue, 'Duplicate report')!
	api.mark_invalid(target, 'Corrected reason')!
	if _ := api.mark_invalid(target, '  ') { assert false, 'accepted empty reason' }
	assert api.invalid_marks()![target] == 'Corrected reason'
	api.unmark_invalid(target)!
	api.unmark_invalid(target)!
	assert api.invalid_marks()! == {issue: 'Duplicate report'}
	// A broken record is reported, rather than silently hiding a triage decision.
	os.write_file(api.invalid_path(issue), 'broken json')!
	if _ := api.invalid_marks() { assert false, 'ignored a corrupt record' }
}

fn test_invalid_target_normalization() ! {
	sha := 'a'.repeat(40)
	assert invalid_target('owner/repo', sha.to_upper())! == sha
	assert invalid_target('owner/repo', 'https://github.com/OWNER/REPO/commit/${sha}')! == sha
	assert invalid_target('owner/repo', 'https://github.com/OWNER/REPO/issues/42/?q=x#comment')! == 'https://github.com/owner/repo/issues/42'
	assert invalid_target('owner/repo', 'https://github.com/owner/repo/pull/42')! != invalid_target('owner/repo', 'https://github.com/owner/repo/issues/42')!
	if _ := invalid_target('owner/repo', 'https://github.com/other/repo/issues/42') {
		assert false, 'accepted another repository'
	}
}

fn test_invalid_tags_in_lists_search_and_clear_without_changing_lifecycle() {
	advs := [['GHSA-one', 'draft', '-', 'high', 'Bounds check', 'abcdef1234', '']]
	entries := [['abcdef1234567890', '2026-11-09', 'Fix bounds check']]
	mut list := TuiList{}
	list.rebuild(entries, advs, advisory_links(advs), 1)
	list.mark_invalid(entries, {'abcdef1234567890': 'No tagged release affected'})
	list.filter(entries, 'no tagged release', 'all')
	assert list.visible == [0]
	for width in [10, 30, 80, 120] {
		line := list.line(0, entries, advs, 1, width, false)
		assert line.starts_with('! ')
		assert clip_line(line, line_width(width)) == line
		assert term.strip_ansi(list.line(0, entries, advs, 1, width, true)) == term.strip_ansi(line)
	}
	// Marking a source does not implicitly mark its linked advisory.
	list.rebuild(advs, advs, advisory_links(advs), 0)
	list.mark_invalid(advs, {'abcdef1234567890': 'No tagged release affected'})
	assert list.line(0, advs, advs, 0, 120, false).starts_with('  ')
	list.mark_invalid(advs, {'ghsa-one': 'No tagged release affected'})
	list.filter(advs, 'invalid', 'draft')
	assert list.visible == [0]
	assert list.line(0, advs, advs, 0, 120, false).starts_with('! ')
	assert advs[0][1] == 'draft'
	list.rebuild(advs, advs, advisory_links(advs), 0)
	list.mark_invalid(advs, map[string]string{})
	list.filter(advs, 'invalid', 'all')
	assert list.visible == []int{}
	assert list.line(0, advs, advs, 0, 120, false).starts_with('  ')
}

fn test_local_invalid_tags_preserve_columns_in_every_view_and_width() {
	title := 'Fix 界 e\u0301 👩🏽‍💻 bounds check '.repeat(10)
	advisory := ['GHSA-abcd-efgh-ijkl', 'draft', '-', 'medium', title, 'f23b8efeec', '']
	commit := ['f23b8efeecd681c45a53c500103adf6f098600ae', '2026-10-30', title]
	issue := ['https://github.com/owner/repo/issues/42', '42', 'issue', 'open', title]
	for view, entry in [advisory, commit, issue, issue] {
		entries := [entry, entry]
		advs := [advisory, advisory]
		mut list := TuiList{}
		list.rebuild(entries, advs, advisory_links(advs), view)
		for width in 1 .. 161 {
			unmarked := term.strip_ansi(list.line(0, entries, advs, view, width, false))
			list.mark_invalid(entries, {invalid_key(entry[0]): 'No released version affected'})
			marked := term.strip_ansi(list.line(1, entries, advs, view, width, false))
			if width < 4 {
				assert marked == unmarked
			} else {
				assert unmarked.starts_with('  ')
				assert marked == '!' + unmarked[1..]
			}
			mut cells := 0
			for g in marked.graphemes() { cells += cell_width(g) }
			assert cells <= line_width(width)
			assert !marked.contains('\n') && !marked.contains('[invalid]')
			assert term.strip_ansi(list.line(1, entries, advs, view, width, true)) == marked
			list.mark_invalid(entries, map[string]string{})
		}
	}
}

// The list tests predate other mark kinds; express invalid tags as marks.
fn (mut list TuiList) mark_invalid(entries [][]string, reasons map[string]string) {
	mut marks := map[string]Mark{}
	for key, reason in reasons {
		marks[key] = Mark{target: key, reason: reason, kind: 'invalid'}
	}
	list.mark(entries, marks, 0)
}

fn test_marks_order_and_symbols() ! {
	advs := [['GHSA-one', 'draft', '-', 'low', 'One'], ['GHSA-two', 'draft', '-', 'low', 'Two'],
		['GHSA-three', 'draft', '-', 'low', 'Three']]
	mut list := TuiList{}
	list.rebuild(advs, advs, advisory_links(advs), 0)
	list.mark(advs, {
		'ghsa-one':   Mark{kind: 'ignore'}
		'ghsa-three': Mark{kind: 'pin', reason: 'triage first'}
	}, 0)
	list.filter(advs, '', 'all')
	assert list.visible == [2, 1, 0]
	assert term.strip_ansi(list.line(2, advs, advs, 0, 120, false)).starts_with('^ ')
	assert term.strip_ansi(list.line(0, advs, advs, 0, 120, false)).starts_with('- ')
	list.filter(advs, 'triage first', 'all')
	assert list.visible == [2]
	// Reports are keyed by finding ID so the mark survives a move to the attic.
	report := ['/x/wave1/ANT-1/REPORT.md', 'high', 'UAF', 'ANT-1', 'Title', '', 'CWE-416', 'wave1', '2026-01-01']
	assert mark_key(report, 4) == 'report:ant-1'
	assert Mark{kind: 'wip', by: 'analyst', reason: 'fixing'}.describe() == 'wip by analyst: fixing'

	dir := os.join_path(os.temp_dir(), 'gsadv-marks-test-${os.getpid()}')
	os.setenv('XDG_STATE_HOME', dir, true)
	defer {
		os.unsetenv('XDG_STATE_HOME')
		os.rmdir_all(dir) or {}
	}
	api := Repository(GitHub{repo: 'owner/repo'})
	assert api.marks_stamp() == ''
	api.set_mark('report:ANT-1', 'pin', '')!
	pinned := api.marks_stamp()
	api.set_mark('report:ANT-1', 'wip', ' drafting ')!
	assert api.marks_stamp() !in ['', pinned]
	mark := api.marks()!['report:ant-1'] or { Mark{} }
	assert mark.kind == 'wip' && mark.reason == 'drafting' && mark.time > 0
	assert api.invalid_marks()!.len == 0
	if _ := api.set_mark('report:ANT-1', 'bogus', '') { assert false, 'accepted an unknown kind' }
	if _ := api.set_mark('report:ANT-1', 'invalid', ' ') { assert false, 'accepted invalid without a reason' }
	api.mark_invalid('report:ANT-1', 'duplicate')!
	assert api.invalid_marks()! == {'report:ant-1': 'duplicate'}
	api.unmark_invalid('report:ANT-1')!
	assert api.marks()!.len == 0
}

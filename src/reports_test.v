module main

import os
import term
import time

const sample_report = '```
============================================================================
ANT-2026-ABCDEFGH  [high]  CWE-416  memory-safety
Use after free in r_bin_close
Location: libr/bin/bin.c:42  in r_bin_close()
Commit:   0123456789
============================================================================
```

Body text mentioning a double free.
'

fn test_parse_report_header() {
	assert parse_report(sample_report) == ['high', 'UAF', 'ANT-2026-ABCDEFGH', 'Use after free in r_bin_close',
		'libr/bin/bin.c:42  in r_bin_close()', 'CWE-416']
	bug := parse_report('```\nANT-2026-X  [NOT SECURITY: ordinary bug]\nCrash on empty file\nLocation: a.c:1\n```\nan integer underflow here')
	assert bug[0] == 'bug'
	assert bug[1] == 'CRASH'
	assert parse_report('```\nANT-2026-X  [NOT SECURITY: ordinary bug]\nWrong size\n```\nan integer underflow here')[1] == 'INT-UNDERFLOW'
	assert parse_report('```\nANT-2026-X  [low]  CWE-9999  dos\nSlow thing\n```\n')[1] == 'DOS'
	assert parse_report('# Plain title\n\ntext')[..4] == ['-', '-', '', 'Plain title']
}

fn test_ini_round_trip() {
	text := '# comment\nantfind = Findings\nattic=Old\n'
	assert parse_ini(text) == {'antfind': 'Findings', 'attic': 'Old'}
	assert set_ini(text, 'attic', 'Done') == '# comment\nantfind = Findings\nattic=Done\n'
	assert set_ini(text, 'label', 'cve') == text + 'label=cve\n'
	assert set_ini(text, 'antfind', none) == '# comment\nattic=Old\n'
	assert set_ini('', 'attic', '') == 'attic=\n'
}

fn test_find_reports_skips_attic() {
	base := os.join_path(os.temp_dir(), 'gsadv-reports-${os.getpid()}')
	defer { os.rmdir_all(base) or {} }
	for dir in ['wave1/A', 'wave1/Attic/B', 'C'] {
		os.mkdir_all(os.join_path(base, dir))!
	}
	os.write_file(os.join_path(base, 'wave1/A/REPORT.md'), '```\nANT-1  [low]  CWE-476  dos\nNull\n```\n')!
	os.write_file(os.join_path(base, 'wave1/Attic/B/REPORT.md'), 'old')!
	os.write_file(os.join_path(base, 'C/REPORT.md'), '```\nANT-2  [critical]  CWE-787  memory-safety\nWrite\n```\n')!
	rows := find_reports(base, 'Attic')
	assert rows.map(it[3]) == ['ANT-2', 'ANT-1']
	assert rows.map(it[7]) == ['.', 'wave1']
	assert find_reports(base, '').len == 3
	assert find_reports(base, 'wave1/Attic').len == 2
	assert find_reports(os.join_path(base, 'missing'), 'Attic').len == 0
	updates := chan [][]string{cap: 4}
	progress := fn [updates] (_ int, batch [][]string) bool {
		return updates.try_push(batch) == .success
	}
	assert find_reports(base, 'Attic', progress) == rows
	mut first := [][]string{}
	for updates.try_pop(mut first) == .success && first.len == 0 {}
	assert first.len == 1 && first[0] in rows
}

fn test_move_to_attic() ! {
	base := os.join_path(os.temp_dir(), 'gsadv-attic-${os.getpid()}')
	defer { os.rmdir_all(base) or {} }
	os.mkdir_all(os.join_path(base, 'wave1/ANT-1'))!
	os.mkdir_all(os.join_path(base, 'ANT-2'))!
	os.write_file(os.join_path(base, 'wave1/ANT-1/REPORT.md'), 'one')!
	os.write_file(os.join_path(base, 'ANT-2/REPORT.md'), 'two')!
	os.write_file(os.join_path(base, 'REPORT.md'), 'top')!
	assert move_to_attic(os.join_path(base, 'wave1/ANT-1/REPORT.md'), base, 'Attic')! == os.join_path(base, 'wave1/Attic/ANT-1')
	assert move_to_attic(os.join_path(base, 'ANT-2/REPORT.md'), base, 'old/Attic')! == os.join_path(base, 'old/Attic/ANT-2')
	assert find_reports(base, 'Attic').len == 1
	if _ := move_to_attic(os.join_path(base, 'REPORT.md'), base, 'Attic') { assert false, 'moved the base directory' }
	if _ := move_to_attic(os.join_path(base, 'x/REPORT.md'), base, '') { assert false, 'accepted an empty attic' }
}

fn test_report_results() ! {
	base := os.join_path(os.temp_dir(), 'gsadv-results-${os.getpid()}')
	defer { os.rmdir_all(base) or {} }
	for name in ['A', 'B', 'C'] {
		os.mkdir_all(os.join_path(base, name))!
		os.write_file(os.join_path(base, name, 'REPORT.md'), '```\nANT-${name}  [low]  CWE-476  dos\nNull\n```\n')!
	}
	os.write_file(os.join_path(base, 'A', 'RESULT.md'), '**Verdict:** confirmed\nReason: ASan crash\n')!
	os.write_file(os.join_path(base, 'B', 'RESULT.md'), 'Summary without a verdict\n')!
	os.write_file(os.join_path(base, 'C', 'SIMILAR.md'), 'No similar bugs\n')!
	rows := find_reports(base, 'Attic')
	assert rows.map(it[9]) == ['confirmed', 'done', '']
	assert rows.map(it[10]) == ['', '', 'similar']
	assert is_report(rows[0][0]) && !is_report(os.join_path(base, 'A', 'RESULT.md'))
	assert similar_path(rows[2][0]) == os.join_path(base, 'C', 'SIMILAR.md')
	assert report_row(rows[0], 120, false).contains(' 👍 ')
	mut list := TuiList{}
	list.rebuild(rows, [], AdvisoryLinks{}, 4)
	list.mark(rows, {mark_key(rows[0], 4): Mark{kind: 'invalid'}}, 4)
	assert term.strip_ansi(list.line(0, rows, [], 4, 120, true)).contains(' 👍 ❌ ')
	assert report_columns(120).contains('STATE')
}

fn test_report_wip_states() ! {
	base := os.join_path(os.temp_dir(), 'gsadv-wip-${os.getpid()}')
	defer { os.rmdir_all(base) or {} }
	report := os.join_path(base, 'ANT-1', 'REPORT.md')
	os.mkdir_all(os.dir(report))!
	os.write_file(report, '```\nANT-1  [low]  CWE-476  dos\nNull\n```\n')!
	assert report_state(report) == ''
	wip := start_wip(report, '/tmp/recovery')
	assert wip == wip_path(report) && os.read_file(wip)!.contains('Recovery files: /tmp/recovery')
	assert report_state(report) == 'working'
	os.write_file(result_path(report), 'Verdict: confirmed\n')!
	assert report_state(report) == 'working confirmed'
	// A process id that cannot exist on this host means the run died.
	os.write_file(wip, 'gsadv fix pid=999999999 host=${os.hostname()!} started=x\n')!
	assert report_state(report) == 'stopped confirmed'
	os.write_file(wip, 'gsadv fix pid=1 host=elsewhere.example started=x\n')!
	assert report_state(report) == 'working confirmed'
	os.rm(wip)!
	assert report_state(report) == 'confirmed'
	os.write_file(advisory_path(report), 'summary: Null dereference\n')!
	assert report_state(report) == 'confirmed advisory'
	start_wip(report, '/tmp/recovery')
	assert report_state(report) == 'working confirmed advisory'
	os.rm(wip)!
	assert report_columns(120).contains('STATE') && !report_columns(120).contains('RESULT')
}

fn test_report_state_icons_fit_the_column() {
	assert report_state_cell('working confirmed advisory similar', true) == '🤖 👍 📝 🔍 ❌'
	assert report_state_cell('false-pos', true).trim_space() == '❌'
	assert report_state_cell('stopped fixed-old', false).trim_space() == '🛑 🔧'
	assert report_state_cell('unclear', false).trim_space() == '❓'
	assert report_state_cell('done', false).trim_space() == '✅'
	assert report_state_cell('', false) == ' '.repeat(report_state_width)
}

fn test_offloaded_report_uses_header_identity_after_download() {
	placeholder := ['/findings/folder/REPORT.md', '-', '-', 'folder', '', '', '', '.',
		'2026-11-27', 'confirmed', 'similar', 'offloaded']
	assert report_row(placeholder, 70, false).contains('folder (offloaded)')
	assert mark_key(placeholder, 4) == ''
	entry := report_with_contents(placeholder, sample_report)
	assert !report_offloaded(entry)
	assert entry[1..7] == ['high', 'UAF', 'ANT-2026-ABCDEFGH', 'Use after free in r_bin_close',
		'libr/bin/bin.c:42  in r_bin_close()', 'CWE-416']
	assert entry[7..] == placeholder[7..11]
	assert mark_key(entry, 4) == 'report:ant-2026-abcdefgh'
}

fn test_finding_advisory_context() ! {
	assert ant_id('Fix overflow ##crash\n\n* OSS-SCAN - ANT-2026-6PEMX3GV\n* More') == 'ANT-2026-6PEMX3GV'
	assert ant_id('ANT-2026-short and ANT-2026-ABCDEFGHI and ANT-26-ABCDEFGH') == ''
	assert ant_id('see ANT-2026-ABCDEFGH.') == 'ANT-2026-ABCDEFGH'
	base := os.join_path(os.temp_dir(), 'gsadv-finding-${os.getpid()}')
	os.setenv('GSADV_ANTFIND', base, true)
	defer {
		os.unsetenv('GSADV_ANTFIND')
		os.rmdir_all(base) or {}
	}
	dir := os.join_path(base, 'wave1', 'Attic', 'ANT-2026-ABCDEFGH')
	os.mkdir_all(dir)!
	os.write_file(os.join_path(dir, 'REPORT.md'), 'report')!
	assert find_finding(base, 'ANT-2026-ABCDEFGH') == dir
	assert find_finding(base, 'ANT-2026-ZZZZZZZZ') == ''
	commit := 'Fix it ##crash\n\n* OSS-SCAN - ANT-2026-ABCDEFGH\n'
	assert finding_context(commit).contains('its report is ${dir}/REPORT.md')
	os.write_file(os.join_path(dir, 'ADVISORY.md'), 'summary: Verified overflow\n---\nDetails\n')!
	context := finding_context(commit)
	assert context.contains('Trust it as the starting point') && context.contains('summary: Verified overflow')
	assert finding_context('Fix it without a finding') == ''
	prompt := render(prompt_new, {
		'finding': context
	})
	assert prompt.contains('summary: Verified overflow') && !prompt.contains('{{finding}}')
}

fn test_commit_advisory() ! {
	base := os.join_path(os.temp_dir(), 'gsadv-commit-advisory-${os.getpid()}')
	repo := os.join_path(base, 'repo')
	dir := os.join_path(base, 'antfind', 'Attic', 'ANT-2026-ABCDEFGH')
	os.mkdir_all(repo)!
	os.mkdir_all(dir)!
	old := os.getwd()
	os.setenv('GSADV_ANTFIND', os.join_path(base, 'antfind'), true)
	defer {
		os.chdir(old) or {}
		os.unsetenv('GSADV_ANTFIND')
		os.rmdir_all(base) or {}
	}
	os.chdir(repo)!
	git := ['git', '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false']
	os.exec(['git', 'init', '-q'])
	os.exec([...git, 'commit', '-q', '--allow-empty', '-m', 'Fix it ##crash\n\n* OSS-SCAN - ANT-2026-ABCDEFGH'])
	os.exec([...git, 'commit', '-q', '--allow-empty', '-m', 'Unrelated'])
	os.write_file(os.join_path(dir, 'REPORT.md'), 'report')!
	assert commit_advisory('HEAD~1') == ''
	os.write_file(os.join_path(dir, 'ADVISORY.md'), 'summary: Overflow\n---\nDetails\n')!
	assert commit_advisory('HEAD~1') == os.join_path(dir, 'ADVISORY.md')
	assert commit_advisory('HEAD') == ''
	assert commit_advisory('nonexistent') == ''
	// The default grep keeps only the fix commit.
	os.exec([...git, 'commit', '-q', '--allow-empty', '-m', 'Other fix ##crash'])
	rows := commits()!
	assert rows.len == 2 && rows[0][3] == '' && rows[1][3] == os.join_path(dir, 'ADVISORY.md')
	assert rows[1][4] == 'ANT-2026-ABCDEFGH'
	assert crow(rows[1], [][]string{}, 100).contains('📝 ADVISORY.md')
	assert crow(rows[1], [][]string{}, 60).contains('📝 Fix it')
	assert !crow(rows[0], [][]string{}, 100).contains('📝')
	acknowledged := ['GHSA-abcd-efgh-ijkl', 'draft', '-', 'high', 'From finding', rows[1][4]]
	assert term.strip_ansi(crow(rows[1], [acknowledged], 80)).contains('📝 GHSA-abcd-efgh-ijkl Fix it')
	direct := ['GL-42', 'opened', '-', 'high', 'Direct link', rows[1][0]]
	assert term.strip_ansi(crow(rows[1], [acknowledged, direct], 60)).contains('📝 GL-42 Fix it')
}

fn test_fix_agent_reaches_report_directory() ! {
	dir := os.join_path(os.temp_dir(), 'gsadv-report-dir-${os.getpid()}')
	checkout := os.join_path(dir, 'checkout')
	finding := os.join_path(dir, 'ANT-2026-ABCDEFGH')
	os.mkdir_all(checkout)!
	os.mkdir_all(os.join_path(finding, 'patches'))!
	old := os.getwd()
	defer {
		os.chdir(old) or {}
		os.rmdir_all(dir) or {}
	}
	report := os.join_path(finding, 'REPORT.md')
	for name in ['REPORT.md', 'RESULT.md', 'WIP.txt', 'poc.c'] {
		os.write_file(os.join_path(finding, name), name)!
	}
	assert report_files(report) == 'patches/, poc.c'
	assert agent_command(agents[0], true, finding, '') == 'claude -p --permission-mode acceptEdits --add-dir "\$3" --output-format stream-json --verbose'
	assert agent_command(agents[1], true, finding, '') == 'codex exec --add-dir "\$3" -'
	assert agent_command(agents[2], true, finding, '') == 'pmai --add-dir "\$3" --progress "\$(cat)"'
	assert agent_command(agents[3], true, finding, '') == agents[3]
	assert agent_command(agents[1], false, '', '') == agents[1]
	assert agent_command(agents[2], false, '', '') == agents[2]
	os.chdir(checkout)!
	stray := os.join_path(checkout, 'ADVISORY.md')
	os.write_file(stray, 'summary: Overflow\n')!
	recover_advisory(report, time.now().unix() + 60)
	assert os.exists(stray) && !os.exists(advisory_path(report))
	recover_advisory(report, time.now().unix() - 60)
	assert !os.exists(stray) && os.read_file(advisory_path(report))! == 'summary: Overflow\n'
	os.write_file(stray, 'other\n')!
	recover_advisory(report, 0)
	assert os.exists(stray) && os.read_file(advisory_path(report))! == 'summary: Overflow\n'
}

module main

import os

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

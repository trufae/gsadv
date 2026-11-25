module main

import os
import time

// Rows are [path, severity, type, id, title, location, cwe, group, date].
// Findings start with a fenced header:
//   ANT-2026-XXXXXXXX  [high]  CWE-416  memory-safety
//   Title
//   Location: file.c:123  in func()
const report_states = ['all', 'critical', 'high', 'medium', 'low', 'bug']

const report_cwe_types = {
	'CWE-416':  'UAF'
	'CWE-415':  'DOUBLE-FREE'
	'CWE-590':  'BAD-FREE'
	'CWE-121':  'STACK-OVF'
	'CWE-122':  'HEAP-OVF'
	'CWE-124':  'UNDERWRITE'
	'CWE-787':  'OOB-WRITE'
	'CWE-125':  'OOB-READ'
	'CWE-126':  'OOB-READ'
	'CWE-127':  'OOB-READ'
	'CWE-129':  'BAD-INDEX'
	'CWE-190':  'INT-OVF'
	'CWE-191':  'INT-UNDERFLOW'
	'CWE-195':  'INT-SIGN'
	'CWE-681':  'INT-CONV'
	'CWE-476':  'NULL-DEREF'
	'CWE-822':  'BAD-PTR'
	'CWE-824':  'BAD-PTR'
	'CWE-843':  'TYPE-CONFUSION'
	'CWE-134':  'FMT-STRING'
	'CWE-77':   'CMD-INJ'
	'CWE-78':   'CMD-INJ'
	'CWE-94':   'CODE-INJ'
	'CWE-89':   'SQL-INJ'
	'CWE-74':   'ESC-INJ'
	'CWE-79':   'XSS'
	'CWE-93':   'CRLF-INJ'
	'CWE-116':  'ESC-INJ'
	'CWE-117':  'LOG-INJ'
	'CWE-150':  'ESC-INJ'
	'CWE-400':  'HANG'
	'CWE-407':  'QUADRATIC'
	'CWE-606':  'HANG'
	'CWE-833':  'DEADLOCK'
	'CWE-834':  'HANG'
	'CWE-835':  'INF-LOOP'
	'CWE-674':  'RECURSION'
	'CWE-405':  'OOM'
	'CWE-409':  'OOM'
	'CWE-770':  'OOM'
	'CWE-789':  'OOM'
	'CWE-1284': 'OOM'
	'CWE-401':  'MEMLEAK'
	'CWE-457':  'UNINIT'
	'CWE-908':  'UNINIT'
	'CWE-200':  'INFO-LEAK'
	'CWE-22':   'PATH'
	'CWE-59':   'SYMLINK'
	'CWE-73':   'PATH'
	'CWE-377':  'TMPFILE'
	'CWE-362':  'RACE'
	'CWE-693':  'SANDBOX'
	'CWE-862':  'SANDBOX'
	'CWE-863':  'SANDBOX'
}

// Most specific phrases first; used when a report has no known CWE.
const report_keywords = [
	['use-after-free', 'UAF'],
	['use after free', 'UAF'],
	['double free', 'DOUBLE-FREE'],
	['double-free', 'DOUBLE-FREE'],
	['over-read', 'OOB-READ'],
	['overread', 'OOB-READ'],
	['stack-buffer-overflow', 'STACK-OVF'],
	['stack buffer overflow', 'STACK-OVF'],
	['heap-buffer-overflow', 'HEAP-OVF'],
	['heap buffer overflow', 'HEAP-OVF'],
	['heap overflow', 'HEAP-OVF'],
	['integer underflow', 'INT-UNDERFLOW'],
	['underflow', 'INT-UNDERFLOW'],
	['integer overflow', 'INT-OVF'],
	['null pointer', 'NULL-DEREF'],
	['null dereference', 'NULL-DEREF'],
	['null deref', 'NULL-DEREF'],
	['out-of-bounds write', 'OOB-WRITE'],
	['out-of-bounds read', 'OOB-READ'],
	['out of bounds', 'OOB-READ'],
	['uninitialized', 'UNINIT'],
	['memory leak', 'MEMLEAK'],
	['infinite loop', 'INF-LOOP'],
	['recursion', 'RECURSION'],
	['quadratic', 'QUADRATIC'],
	['hang', 'HANG'],
	['command injection', 'CMD-INJ'],
	['path traversal', 'PATH'],
	['symlink', 'SYMLINK'],
	['sandbox', 'SANDBOX'],
	['race', 'RACE'],
	['assert', 'ASSERT'],
	['crash', 'CRASH'],
	['leak', 'LEAK'],
]

// Match at word starts, so hang matches hangs but not changes; punctuation counts as a space.
fn report_keyword_type(text string) string {
	words := ' ' + text.to_lower().bytes().map(if it.is_alnum() { it } else { u8(` `) }).bytestr()
	for k in report_keywords {
		phrase := k[0].replace('-', ' ')
		if words.contains(' ${phrase}') { return k[1] }
	}
	return ''
}

// Parse one REPORT.md into a row; files without the fenced header keep their first heading.
fn parse_report(text string) []string {
	lines := text.split_into_lines().map(it.trim_space())
	mut severity, mut cwe, mut class, mut id, mut title, mut location := '-', '', '', '', '', ''
	for i, line in lines {
		if line == '' || line.starts_with('`') || line.starts_with('====') { continue }
		fields := line.fields()
		if id == '' && fields.len >= 2 && fields[1].starts_with('[') && line.contains(']') {
			id = fields[0]
			tag := line.find_between('[', ']').to_lower()
			severity = if tag.starts_with('not security') { 'bug' } else { tag }
			rest := line.all_after(']').fields()
			cwe = rest.filter(it.starts_with('CWE-'))[0] or { '' }
			class = rest.filter(!it.starts_with('CWE-'))[0] or { '' }
			for next in lines[i + 1..] {
				if next.starts_with('Location:') {
					location = next.all_after('Location:').trim_space()
					break
				}
				if title == '' && next != '' && !next.starts_with('====') && !next.starts_with('`') { title = next }
			}
			break
		}
		// No header: fall back to the first non-fence line.
		title = line.trim_left('#').trim_space()
		break
	}
	mut typ := report_cwe_types[cwe] or { report_keyword_type(title) }
	if typ == '' && (severity == 'bug' || class == '') { typ = report_keyword_type(text) }
	if typ == '' { typ = class.to_upper() }
	return [severity, if typ == '' { '-' } else { typ }, id, title, location, cwe]
}

fn walk_reports(base string, dir string, attic string, mut paths []string) {
	for name in os.ls(dir) or { return } {
		path := os.join_path(dir, name)
		if os.is_dir(path) {
			// Symlinked directories could loop; the attic matches a name or a path below base.
			if os.is_link(path) { continue }
			if attic != '' && (name == attic || path[base.len + 1..] == attic) { continue }
			walk_reports(base, path, attic, mut paths)
		} else if name == 'REPORT.md' {
			paths << path
		}
	}
}

fn report_rank(severity string) int {
	return match severity {
		'critical' { 0 }
		'high' { 1 }
		'medium' { 2 }
		'low' { 3 }
		'bug' { 5 }
		else { 4 }
	}
}

// Most severe first, then by path.
fn find_reports(base string, attic string) [][]string {
	mut paths := []string{}
	if os.is_dir(base) { walk_reports(base, base, attic.trim('/'), mut paths) }
	mut rows := [][]string{}
	for path in paths {
		r := parse_report(os.read_file(path) or { '' })
		// The group is the directory above the finding's own, e.g. wave1.
		rel := os.dir(path)[base.len..].trim_left('/')
		group := if rel.contains('/') { os.dir(rel) } else { '.' }
		id := if r[2] != '' { r[2] } else { os.file_name(os.dir(path)) }
		rows << [path, r[0], r[1], id, r[3], r[4], r[5], group,
			time.unix(os.file_last_mod_unix(path)).local().ymmdd()]
	}
	rows.sort_with_compare(fn (a &[]string, b &[]string) int {
		ra, rb := report_rank((*a)[1]), report_rank((*b)[1])
		if ra != rb { return ra - rb }
		return compare_strings((*a)[0], (*b)[0])
	})
	return rows
}

fn reports_base() string {
	dir := project_setting('antfind')
	return if os.is_abs_path(dir) { dir } else { os.join_path(project_root(), dir) }
}

fn report_columns(w int) string {
	return if w < 60 { 'TITLE' } else if w < 90 {
		'   ${'TYPE':-14} TITLE'
	} else if w < 130 {
		'   ${'ID':-18} ${'TYPE':-14} TITLE'
	} else {
		'   ${'ID':-18} ${'TYPE':-14} ${'CWE':-9} ${'GROUP':-24} TITLE'
	}
}

fn report_row(r []string, w int) string {
	if r.len < 9 { return clip_line(r.join(' '), line_width(w)) }
	icon := if r[1] == 'bug' { '⚫' } else { severity_icon(r[1]) }
	line := if w < 60 { r[4] } else if w < 90 {
		'${icon} ${r[2]:-14} ${r[4]}'
	} else if w < 130 {
		'${icon} ${r[3]:-18} ${r[2]:-14} ${r[4]}'
	} else {
		'${icon} ${r[3]:-18} ${r[2]:-14} ${r[6]:-9} ${table_cell(r[7], 24)} ${r[4]}'
	}
	return clip_line(line, line_width(w))
}

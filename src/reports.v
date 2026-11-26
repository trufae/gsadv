module main

import os
import time

// Rows are [path, severity, type, id, title, location, cwe, group, date, state, similar].
// state contains the activity, verdict, and advisory labels that apply;
// similar is set when a similar-bugs search saved SIMILAR.md there.
// Offloaded reports have an extra field until their contents are available.
// Findings start with a fenced header:
//   ANT-2026-XXXXXXXX  [high]  CWE-416  memory-safety
//   Title
//   Location: file.c:123  in func()
const report_states = ['all', 'critical', 'high', 'medium', 'low', 'bug']
const report_state_width = 14

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

type ReportProgress = fn (int, [][]string) bool

struct ReportScan {
	base string
	attic string
	progress ?ReportProgress
mut:
	rows [][]string
	dirs int
	published int
	last_update time.Time
}

fn (mut scan ReportScan) publish(first_report bool) {
	if progress := scan.progress {
		if !first_report && time.since(scan.last_update) < 200 * time.millisecond { return }
		if progress(scan.dirs, scan.rows[scan.published..].clone()) {
			scan.published = scan.rows.len
		}
		scan.last_update = time.now()
	}
}

fn (mut scan ReportScan) walk(dir string) {
	scan.dirs++
	scan.publish(false)
	for name in os.ls(dir) or { return } {
		path := os.join_path(dir, name)
		info := os.stat(path) or { continue }
		kind := info.get_filetype()
		if kind == .directory {
			// Symlinked directories could loop; the attic matches a name or a path below base.
			if os.is_link(path) { continue }
			if scan.attic != '' && (name == scan.attic || path.trim_string_left(scan.base).trim_left('/') == scan.attic) { continue }
			scan.walk(path)
		} else if name == 'REPORT.md' && kind == .regular {
			// The group is the directory above the finding's own, e.g. wave1.
			rel := os.dir(path).trim_string_left(scan.base).trim_left('/')
			group := if rel.contains('/') { os.dir(rel) } else { '.' }
			mut entry := [path, '-', '-', os.file_name(os.dir(path)), '', '', '', group,
				time.unix(info.mtime).local().ymmdd(), report_state(path),
				if os.exists(similar_path(path)) { 'similar' } else { '' }]
			if report_file_offloaded(path) {
				entry << 'offloaded'
			} else {
				entry = report_with_contents(entry, os.read_file(path) or { '' })
			}
			scan.rows << entry
			scan.publish(scan.rows.len == 1)
		}
	}
}

fn report_file_offloaded(path string) bool {
	$if macos {
		// SF_DATALESS from <sys/stat.h> is hidden in the compiler's POSIX mode.
		flag := u32(0x40000000)
		mut info := C.stat{}
		return unsafe { C.stat(&char(path.str), &info) } == 0 && (info.st_flags & flag) != 0
	} $else {
		return false
	}
}

fn report_offloaded(entry []string) bool {
	return entry.len > 11 && entry[11] == 'offloaded'
}

fn report_with_contents(entry []string, text string) []string {
	r := parse_report(text)
	id := if r[2] != '' { r[2] } else { entry[3] }
	return [entry[0], r[0], r[1], id, r[3], r[4], r[5], entry[7], entry[8], entry[9], entry[10]]
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
fn sort_reports(mut rows [][]string) {
	rows.sort_with_compare(fn (a &[]string, b &[]string) int {
		ra, rb := report_rank((*a)[1]), report_rank((*b)[1])
		if ra != rb { return ra - rb }
		return compare_strings((*a)[0], (*b)[0])
	})
}

fn find_reports(base string, attic string, progress ...ReportProgress) [][]string {
	if !os.is_dir(base) { return [][]string{} }
	mut scan := ReportScan{base: os.norm_path(base), attic: attic.trim('/'),
		progress: if progress.len > 0 { ?ReportProgress(progress[0]) } else { none }, last_update: time.now()}
	scan.walk(scan.base)
	sort_reports(mut scan.rows)
	return scan.rows
}

fn is_report(path string) bool {
	return os.file_name(path) == 'REPORT.md' && os.is_file(path)
}

fn similar_path(report string) string {
	return os.join_path(os.dir(report), 'SIMILAR.md')
}

fn C.kill(pid int, sig int) int

fn wip_path(report string) string {
	return os.join_path(os.dir(report), 'WIP.txt')
}

// The first line identifies the fixing process; the agent's output follows.
fn start_wip(report string, recovery string) string {
	path := wip_path(report)
	host := os.hostname() or { '' }
	header := 'gsadv fix pid=${os.getpid()} host=${host} started=${time.now().format_ss()}\nRecovery files: ${recovery}\n\n'
	os.write_file(path, header) or {
		eprintln('Could not create ${path}: ${err}')
		return ''
	}
	return path
}

// A WIP.txt whose process is gone on this host belongs to a failed or interrupted run.
fn wip_alive(path string) bool {
	mut file := os.open(path) or { return false }
	defer { file.close() }
	mut buf := []u8{len: 256}
	n := file.read(mut buf) or { return false }
	mut fields := map[string]string{}
	for field in buf[..n].bytestr().all_before('\n').fields() {
		if field.contains('=') { fields[field.all_before('=')] = field.all_after_first('=') }
	}
	host := fields['host'] or { '' }
	if host != '' && host != (os.hostname() or { '' }) { return true }
	pid := (fields['pid'] or { '0' }).int()
	return pid > 0 && C.kill(pid, 0) == 0
}

fn report_state(report string) string {
	mut labels := []string{cap: 3}
	wip := wip_path(report)
	if regular_report_file(wip) && !report_file_offloaded(wip) {
		labels << if wip_alive(wip) { 'working' } else { 'stopped' }
	}
	result := report_result(report)
	if result != '' { labels << result }
	if os.is_file(advisory_path(report)) { labels << 'advisory' }
	return labels.join(' ')
}

fn advisory_path(report string) string {
	return os.join_path(os.dir(report), 'ADVISORY.md')
}

// Move an ADVISORY.md the fix agent wrote in the checkout since started next to the report,
// for agents that cannot write outside the current directory.
fn recover_advisory(report string, started i64) {
	target := advisory_path(report)
	stray := os.join_path(os.getwd(), 'ADVISORY.md')
	if os.exists(target) || !os.is_file(stray) || os.file_last_mod_unix(stray) < started { return }
	os.mv_by_cp(stray, target) or {
		eprintln('Could not move ${stray} to ${target}: ${err}')
		return
	}
	println('Moved the advisory draft from the checkout to ${target}')
}

// Supporting files next to the report (reproducers, patches, notes) for the fix prompt;
// gsadv's own state files are left out. Directories end with a slash.
fn report_files(report string) string {
	dir := os.dir(report)
	mut names := []string{}
	for name in os.ls(dir) or { [] } {
		if name in ['REPORT.md', 'WIP.txt', 'RESULT.md'] { continue }
		names << if os.is_dir(os.join_path(dir, name)) { name + '/' } else { name }
	}
	names.sort()
	return if names.len == 0 { 'none' } else { names.join(', ') }
}

// The first finding ID in text, e.g. from "* OSS-SCAN - ANT-2026-6PEMX3GV" in a fix commit.
fn ant_id(text string) string {
	mut i := 0
	for {
		i = text.index_after('ANT-', i) or { return '' }
		id := text#[i..i + 17]
		if id.len == 17 && id[4..8].bytes().all(it.is_digit()) && id[8] == `-`
			&& id[9..].bytes().all(it.is_digit() || (it >= `A` && it <= `Z`))
			&& (i + 17 == text.len || !text[i + 17].is_alnum()) {
			return id
		}
		i += 4
	}
	return ''
}

// The directory of finding id below base, including the attic where fixed findings go.
fn find_finding(base string, id string) string {
	for name in os.ls(base) or { return '' } {
		path := os.join_path(base, name)
		if !os.is_dir(path) || os.is_link(path) { continue }
		if name == id && os.is_file(os.join_path(path, 'REPORT.md')) { return path }
		found := find_finding(path, id)
		if found != '' { return found }
	}
	return ''
}

// Finding directories below dir by ID, including the attic.
fn finding_dirs(dir string, mut dirs map[string]string) {
	for name in os.ls(dir) or { return } {
		path := os.join_path(dir, name)
		if !os.is_dir(path) || os.is_link(path) { continue }
		if name.starts_with('ANT-') && os.is_file(os.join_path(path, 'REPORT.md')) && name !in dirs {
			dirs[name] = path
		}
		finding_dirs(path, mut dirs)
	}
}

// The ADVISORY.md of the finding a fix commit message references, or '' when there is none.
fn commit_advisory(commit string) string {
	r := os.exec(['git', 'log', '-1', '--format=%B', '--no-show-signature', commit, '--'])
	if r.exit_code != 0 { return '' }
	id := ant_id(r.output)
	if id == '' { return '' }
	dir := find_finding(reports_base(), id)
	path := os.join_path(dir, 'ADVISORY.md')
	return if dir != '' && os.is_file(path) { path } else { '' }
}

// Prompt text for a source that references a finding: its ADVISORY.md is trusted.
fn finding_context(evidence string) string {
	id := ant_id(evidence)
	if id == '' { return '' }
	dir := find_finding(reports_base(), id)
	if dir == '' { return '' }
	report := os.join_path(dir, 'REPORT.md')
	advisory := os.read_file(os.join_path(dir, 'ADVISORY.md')) or {
		return '\nThe source references finding ${id}; its report is ${report}. Read it as evidence;\nfindings come from automated analysis and may be false positives.\n'
	}
	return '\nThe source references finding ${id} (${report}). The agent that confirmed and fixed it wrote\n' +
		'the advisory draft below. Trust it as the starting point: keep its verified analysis, correct only\n' +
		'what the source shows to be wrong or incomplete, and fill in fields it left empty.\n\n' +
		'Finding advisory draft (ADVISORY.md):\n${advisory.trim_space()}\n'
}

fn result_path(report string) string {
	return os.join_path(os.dir(report), 'RESULT.md')
}

// Short label for the verdict in RESULT.md; empty when no fix has run.
fn report_result(report string) string {
	path := result_path(report)
	if !regular_report_file(path) { return '' }
	if report_file_offloaded(path) { return 'done' }
	text := os.read_file(path) or { return '' }
	verdict, _ := fix_verdict(text)
	return match verdict {
		'confirmed' { 'confirmed' }
		'false positive' { 'false-pos' }
		'already fixed' { 'fixed-old' }
		'inconclusive' { 'unclear' }
		else { 'done' }
	}
}

fn regular_report_file(path string) bool {
	info := os.stat(path) or { return false }
	return info.get_filetype() == .regular
}

fn report_state_cell(labels string, invalid bool) string {
	mut icons := labels.fields().map(match it {
		'working' { '🤖' }
		'stopped' { '🛑' }
		'confirmed' { '👍' }
		'advisory' { '📝' }
		'similar' { '🔍' }
		'false-pos' { '❌' }
		'fixed-old' { '🔧' }
		'unclear' { '❓' }
		'done' { '✅' }
		else { '' }
	})
	if invalid && '❌' !in icons { icons << '❌' }
	return table_cell(icons.join(' '), report_state_width)
}

fn report_hint(report []string) string {
	if report_offloaded(report) { return '${report[3]} | Offloaded by macOS. Enter downloads and previews it.' }
	if report.len < 11 || (report[9] == '' && report[10] == '') {
		return '${report[3]} | ${report[1]} | ${report[6]} | ${report[5]} | ${report[0]}'
	}
	mut details := [report[3]]
	for state in report[9].fields() {
		details << match state {
			'working', 'stopped' { 'fix ${state} (w views WIP.txt)' }
			'advisory' { 'advisory draft (d views ADVISORY.md)' }
			else { 'result: ${state} (o views RESULT.md)' }
		}
	}
	if report[10] != '' { details << 'similar bugs saved (s views SIMILAR.md)' }
	details << report[0]
	return details.join(' | ')
}

fn reports_base() string {
	dir := project_setting('antfind')
	return if os.is_abs_path(dir) { dir } else { os.join_path(project_root(), dir) }
}

fn report_columns(w int) string {
	state := table_cell('STATE', report_state_width)
	return if w < 60 { 'TITLE' } else if w < 90 {
		'   ${'TYPE':-14} ${state} TITLE'
	} else if w < 130 {
		'   ${'ID':-18} ${'TYPE':-14} ${state} TITLE'
	} else {
		'   ${'ID':-18} ${'TYPE':-14} ${state} ${'CWE':-9} ${'GROUP':-24} TITLE'
	}
}

fn report_row(r []string, w int, invalid bool) string {
	if r.len < 10 { return clip_line(r.join(' '), line_width(w)) }
	title := if report_offloaded(r) {
		if w < 90 { '${r[3]} (offloaded)' } else { 'Offloaded by macOS' }
	} else { r[4] }
	labels := if r.len > 10 { '${r[9]} ${r[10]}' } else { r[9] }
	state := report_state_cell(labels, invalid)
	icon := if r[1] == 'bug' { '⚫' } else { severity_icon(r[1]) }
	line := if w < 60 { title } else if w < 90 {
		'${icon} ${r[2]:-14} ${state} ${title}'
	} else if w < 130 {
		'${icon} ${r[3]:-18} ${r[2]:-14} ${state} ${title}'
	} else {
		'${icon} ${r[3]:-18} ${r[2]:-14} ${state} ${r[6]:-9} ${table_cell(r[7], 24)} ${title}'
	}
	return clip_line(line, line_width(w))
}

// Move the finding's directory into the attic next to it (wave1/X -> wave1/Attic/X),
// or below base when attic is a path such as wave1/Attic.
fn move_to_attic(path string, base string, attic string) !string {
	name := attic.trim('/')
	if name == '' { return error('the attic setting is empty; press , to set it') }
	dir := os.dir(path)
	if dir.trim_right('/') == base.trim_right('/') { return error('${path} is not in a finding directory') }
	parent := if name.contains('/') { os.join_path(base, name) } else { os.join_path(os.dir(dir), name) }
	dest := os.join_path(parent, os.file_name(dir))
	if os.exists(dest) { return error('${dest} already exists') }
	os.mkdir_all(parent)!
	os.rename(dir, dest)!
	return dest
}

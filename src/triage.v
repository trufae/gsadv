module main

import os
import json2
import crypto.sha256
import time

// Local triage marks are independent of the advisory lifecycle. They live in the
// shared state directory, so every gsadv process for the repository sees them.
const mark_kinds = ['important', 'wip', 'pin', 'ignore', 'invalid']

struct Mark {
	target string
	reason string // the note; required for invalid
	kind   string // empty in records written before other kinds existed: invalid
	by     string
	time   i64
}

fn mark_symbol(kind string) string {
	return match kind {
		'invalid' { '!' }
		'important' { '*' }
		'wip' { '@' }
		'pin' { '^' }
		'ignore' { '-' }
		else { '' }
	}
}

fn (m Mark) describe() string {
	if m.kind == '' { return '' }
	mut parts := [m.kind]
	if m.by != '' { parts << 'by ${m.by}' }
	if m.time > 0 { parts << time.unix(m.time).local().format() }
	return parts.join(' ') + if m.reason == '' { '' } else { ': ${m.reason}' }
}

fn invalid_key(input string) string {
	return input.to_lower()
}

fn invalid_target(repo string, input string) !string {
	return Repository(GitHub{repo: repo}).invalid_target(input)
}

fn (api Repository) invalid_target(input string) !string {
	// Reports are keyed by their finding ID, which survives moving them to the attic.
	if input.starts_with('report:') { return invalid_key(input) }
	if input.to_lower().starts_with('ghsa-') {
		return invalid_key(input)
	}
	if api.provider == 'gitlab' && input.to_upper().starts_with('GL-') {
		return invalid_key('${api.url()}/-/issues/${gitlab_iid(input.to_upper())!}')
	}
	s := api.source(input)!
	if s.kind != 'commit' { return invalid_key(s.url) }
	if s.ref.len == 40 && s.ref.bytes().all(it.is_hex_digit()) {
		return invalid_key(s.ref)
	}
	// Short hashes and refs must resolve to the same full hash used by the list.
	r := os.exec(['git', 'rev-parse', '--verify', '--end-of-options', '${s.ref}^{commit}'])
	if r.exit_code != 0 {
		return error('cannot resolve commit ${s.ref}; use its full SHA or the matching checkout')
	}
	return invalid_key(r.output.trim_space())
}

fn (api Repository) invalid_path(target string) string {
	return os.join_path(api.state_path('invalid', ''), sha256.hexhash(api.invalid_target(target) or { invalid_key(target) }) + '.json')
}

fn (api Repository) marks() !map[string]Mark {
	dir := api.state_path('invalid', '')
	mut marks := map[string]Mark{}
	if !os.exists(dir) { return marks }
	for name in os.ls(dir)! {
		if !name.ends_with('.json') { continue }
		path := os.join_path(dir, name)
		record := json2.decode[Mark](os.read_file(path)!)!
		mark := Mark{
			...record
			kind: if record.kind == '' { 'invalid' } else { record.kind }
		}
		if mark.target == '' || mark.kind !in mark_kinds || (mark.kind == 'invalid' && mark.reason.trim_space() == '') {
			return error('invalid local triage record: ${path}')
		}
		marks[invalid_key(mark.target)] = mark
		if api.provider == 'gitlab' {
			if s := api.source(mark.target) {
				if s.kind == 'issues' { marks['gl-${s.ref}'] = mark }
			}
		}
	}
	return marks
}

// Changes when any process adds, replaces or removes a mark. Records are tiny,
// so compare contents: modification times only have one-second resolution.
fn (api Repository) marks_stamp() string {
	dir := api.state_path('invalid', '')
	mut names := os.ls(dir) or { return '' }
	names.sort()
	return sha256.hexhash(names.map('${it}\n' + os.read_file(os.join_path(dir, it)) or { '' }).join('\n'))
}

fn (api Repository) invalid_marks() !map[string]string {
	mut reasons := map[string]string{}
	for key, mark in api.marks()! {
		if mark.kind == 'invalid' { reasons[key] = mark.reason }
	}
	return reasons
}

// One mark per item: setting a mark replaces any previous one.
fn (api Repository) set_mark(target string, kind string, note string) ! {
	if kind !in mark_kinds { return error('unknown mark: ${kind}') }
	if target == '' || (kind == 'invalid' && note.trim_space() == '') {
		return error('an invalid tag requires a target and a reason')
	}
	path := api.invalid_path(target)
	os.mkdir_all(os.dir(path), mode: 0o700)!
	tmp := '${path}.${os.getpid()}.tmp'
	defer { os.rm(tmp) or {} }
	by := os.getenv_opt('USER') or { os.loginname() or { '' } }
	os.write_file(tmp, json2.encode(Mark{api.invalid_target(target)!, note.trim_space(), kind, by, time.now().unix()}))!
	os.rename(tmp, path)!
}

fn (api Repository) mark_invalid(target string, reason string) ! {
	api.set_mark(target, 'invalid', reason)!
}

fn (api Repository) unmark_invalid(target string) ! {
	path := api.invalid_path(target)
	if os.exists(path) { os.rm(path)! }
}

fn marked_row(line string, symbol string, width int) string {
	if width < 4 { return clip_line(line, line_width(width)) }
	// Reserve the same two cells on every row so local marks cannot shift columns.
	mark := if symbol == '' { '  ' } else { symbol + ' ' }
	return clip_line(mark + line, line_width(width))
}

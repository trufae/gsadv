module main

import os
import term
import encoding.utf8.east_asian

// Count terminal cells, keeping combining characters and emoji sequences together.
fn cell_width(grapheme string) int {
	if grapheme.len == 1 && grapheme[0] < 0x80 { return 1 }
	mut width := 0
	for r in grapheme.runes() {
		rune_width := term.printable_len(r.str())
		if rune_width > 0 {
			width = int_max(width, int_max(rune_width, east_asian.display_width(r.str(), 1)))
		}
		if r == 0xfe0f || (r >= 0x1f1e6 && r <= 0x1f1ff) { width = 2 }
	}
	return width
}

// Keep only SGR styling, flatten control characters, and never split a grapheme.
// Every list entry occupies exactly one physical row, even with Unicode text.
fn clip_line(text string, width int) string {
	if width <= 0 { return '' }
	mut out := ''
	mut used := 0
	mut styled := false
	mut i := 0
	for i < text.len {
		if text[i] == 0x1b {
			start := i
			i++
			if i < text.len && text[i] == `[` {
				i++
				for i < text.len && (text[i] < 0x40 || text[i] > 0x7e) { i++ }
				if i < text.len {
					if text[i] == `m` && text[start + 2..i].bytes().all(it.is_digit() || it in [`;`, `:`]) {
						out += text[start..i + 1]
						styled = true
					}
					i++
				}
			} else if i < text.len && text[i] in [`]`, `P`, `X`, `^`, `_`] {
				i++
				for i < text.len && text[i] != 7 && text[i] != 0x1b { i++ }
				if i < text.len {
					i += if text[i] == 0x1b && i + 1 < text.len && text[i + 1] == `\\` { 2 } else { 1 }
				}
			} else {
				for i < text.len && text[i] >= 0x20 && text[i] <= 0x2f { i++ }
				if i < text.len { i++ }
			}
			continue
		}
		start := i
		for i < text.len && text[i] != 0x1b { i++ }
		for g in text[start..i].graphemes() {
			part := if g.runes().any(it < 0x20 || (it >= 0x7f && it < 0xa0)) { ' ' } else { g }
			cells := cell_width(part)
			if used + cells > width {
				return out + if styled { '\x1b[0m' } else { '' }
			}
			out += part
			used += cells
		}
	}
	return out + if styled { '\x1b[0m' } else { '' }
}

fn terminal_size() (int, int) {
	w, h := term.get_terminal_size()
	return int_max(1, w), int_max(1, h)
}

fn line_width(w int) int {
	return int_max(1, w - 1)
}

struct TuiLayout {
	head int
	page int
	foot int
}

// Sacrifice chrome before list space; even a one-row terminal has a selection.
fn tui_layout(height int, headers int, footers int) TuiLayout {
	h := int_max(1, height)
	head := if h >= headers + footers + 1 { headers } else if h >= 3 { int_min(1, headers) } else { 0 }
	foot := int_min(footers, h - head - 1)
	return TuiLayout{head, h - head - foot, foot}
}

fn list_top(top int, sel int, count int, page int) int {
	return int_min(int_max(0, count - page), int_max(0, int_min(int_max(top, sel - page + 1), sel)))
}

fn list_frame(layout TuiLayout, headers []string, body []string, footers []string) []string {
	mut lines := headers[..layout.head].clone()
	for i in 0 .. layout.page { lines << if i < body.len { body[i] } else { '' } }
	lines << footers[footers.len - layout.foot..]
	return lines
}

fn tui_tabs(tabs []string, view int, width int) string {
	short := tabs.map(it.all_before(' '))
	mut active := short.clone()
	active[view] = tabs[view]
	for labels in [tabs, active, short] {
		line := labels.map(if it == labels[view] { term.inverse('[${it}]') } else { it }).join(' | ')
		plain := term.strip_ansi(line)
		if clip_line(plain, width) == plain { return line }
	}
	return term.inverse(clip_line('[${tabs[view]}]', width))
}

struct TuiScreen {
mut:
	lines []string
	clipped map[string]string
	width int
}

// Address rows explicitly: no newlines, terminal wrapping, or full-screen clears.
// Updating only changed rows also makes a no-op reload produce no screen traffic.
fn (mut screen TuiScreen) render(lines []string, width int, height int) string {
	w, h := int_max(1, width), int_max(1, height)
	mut next := []string{len: h}
	mut clipped := map[string]string{}
	mut out := ''
	for i in 0 .. h {
		line := if i < lines.len { lines[i] } else { '' }
		// Reuse clipping even when scrolling moves a row to a different position.
		next[i] = if screen.width == w {
			screen.clipped[line] or { clip_line(line, line_width(w)) }
		} else { clip_line(line, line_width(w)) }
		clipped[line] = next[i]
		if screen.width != w || screen.lines.len != h || next[i] != screen.lines[i] {
			out += '\x1b[${i + 1};1H\x1b[0m${next[i]}\x1b[0m\x1b[K'
		}
	}
	screen.lines = next
	// Bound the cache to the current frame; old views and widths are discarded.
	screen.clipped = clipped
	screen.width = w
	// Disable autowrap during painting, including when a resize races this frame.
	return if out == '' { '' } else { '\x1b[?7l${out}\x1b[?7h' }
}

fn (mut screen TuiScreen) draw(lines []string, w int, h int) {
	out := screen.render(lines, w, h)
	nw, nh := terminal_size()
	if nw != w || nh != h {
		// A slow dialog may finish formatting after a resize. Discard that frame.
		screen.width = 0
		return
	}
	if out != '' {
		print(out)
		os.flush()
	}
}

const tui_enter = '\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h'
const tui_leave = '\x1b[0m\x1b[?7h\x1b[?1000l\x1b[?1006l\x1b[?25h\x1b[?1049l'

fn wrap_text(text string, width int) []string {
	mut lines := []string{}
	for line in text.split('\n') {
		mut part := ''
		mut used := 0
		for g in term.strip_ansi(clip_line(line, line.len)).graphemes() {
			cells := cell_width(g)
			if used + cells > width && part != '' {
				lines << part
				part, used = '', 0
			}
			part += if cells > width { '?' } else { g }
			used += int_min(cells, width)
		}
		lines << part
	}
	return lines
}

// Menus and confirmations can be read a page at a time at any terminal size.
fn tui_dialog(text string) string {
	mut screen := TuiScreen{}
	mut top := 0
	for {
		w, h := terminal_size()
		lines := wrap_text(text, line_width(w))
		page := int_max(1, h - 1)
		top = int_min(int_max(0, top), int_max(0, lines.len - page))
		mut frame := lines[top..int_min(lines.len, top + page)].clone()
		if h > 1 {
			for frame.len < page { frame << '' }
			frame << 'j/k: scroll; choose key; Enter/Esc: cancel'
		}
		screen.draw(frame, w, h)
		k := key(w, h)
		match k {
			'' {}
			'j', '\x1b[B' { top++ }
			'k', '\x1b[A' { top-- }
			'J', '\x1b[6~', ' ' { top += page }
			'K', '\x1b[5~' { top -= page }
			else { return k }
		}
	}
	return ''
}

fn input_line(prompt string, text string, width int) string {
	mut text_width := 0
	for g in text.graphemes() { text_width += cell_width(g) }
	reserved := int_min(text_width, int_max(1, width / 2))
	label := clip_line(prompt, int_max(0, width - reserved))
	available := int_max(0, width - term.printable_len(label))
	mut tail := ''
	mut used := 0
	for g in text.graphemes().reverse() {
		cells := cell_width(g)
		if used + cells > available { break }
		tail = g + tail
		used += cells
	}
	return label + tail
}

const tui_help = 'tab/shift-tab: next/previous view (advisories/commits/issues/PRs or MRs)
j/k or mouse wheel: move; J/K or PgDn/PgUp (AvPág/RePág): move ten rows
enter: view advisory/commit/issue/PR; e: edit advisory; r: AI review selected item; n: new draft
M: edit and post a discussion comment on the selected issue/PR/MR
b: find similar bugs using the selected advisory or source as a template
C: manage advisory credits (finder, reporter, fix developer and other roles)
c (or a): request CVE; d: accept/reopen as draft; p: publish; x: close
i: tag the selected item invalid locally (with a reason); I: remove the tag
s: advisory status; m: actions menu; f/F: next/previous state filter in the current tab
In issues/PRs/MRs, press f once from all to show only open items; each tab remembers its filter.
/: filter the current list by text (Enter applies; empty clears; Esc cancels)
l: change the shared issues/PRs/MRs label filter (empty shows all labels);
   in commits, change the git log --grep regex (empty shows all commits)
g: reload; A: cycle AI agent
?: this help; q or Ctrl+C: quit

Severity: 🔴 critical, 🟠 high, 🟡 medium, 🟢 low, ⚪ unknown.
Commit circles use linked advisory severity or a keyword estimate from the subject.
Release: 🟢 released, 🟡 prerelease, 🔵 draft, 🟠 upcoming,
🔴 no release, 🟣 mixed, ⚪ unknown.
States: triage (private report), draft, published, closed.
CVE assignment is separate from the advisory state and happens asynchronously.
Use s to check the assigned CVE; GitHub REST does not expose pending requests.
requested* means gsadv recorded an accepted request locally, across restarts.
It is not a live queue status; s shows when the request was accepted.'

fn color(state string, s string) string {
	return if !term.can_show_color_on_stdout() {
		s
	} else {
		match state {
			'draft' { term.yellow(s) }
			'triage' { term.cyan(s) }
			'published' { term.green(s) }
			else { term.dim(s) }
		}
	}
}

fn severity_icon(severity string) string {
	return match severity.to_lower() {
		'critical' { '🔴' }
		'high' { '🟠' }
		'medium', 'moderate' { '🟡' }
		'low' { '🟢' }
		else { '⚪' }
	}
}

fn release_icon(state string) string {
	return match state {
		'released' { '🟢' }
		'prerelease' { '🟡' }
		'draft' { '🔵' }
		'upcoming' { '🟠' }
		'no release' { '🔴' }
		'mixed' { '🟣' }
		else { '⚪' }
	}
}

fn crow(c []string, advs [][]string, w int) string {
	i := if c.len > 0 { adv_of(advs, c[0]) } else { -1 }
	return commit_row(c, if i >= 0 { advs[i] } else { []string{} }, w)
}

fn commit_row(c []string, a []string, w int) string {
	if c.len < 3 {
		return clip_line(c.join(' '), line_width(w))
	}
	mark := if a.len < 5 { term.dim('${'-':-20}') } else { color(a[1], '${a[0]:-20}') }
	severity := if a.len >= 5 && severity_icon(a[3]) != '⚪' {
		a[3]
	} else {
		commit_severity(c[2])
	}
	line := if w < 40 { c[2] } else if w < 80 {
		'${severity_icon(severity)} ${c[0]#[..10]} ${c[2]}'
	} else { '${severity_icon(severity)} ${c[0]#[..10]} ${c[1]} ${mark} ${c[2]}' }
	return clip_line(line, line_width(w))
}

fn irow(item []string, advs [][]string, w int) string {
	i := if item.len > 0 { adv_of(advs, item[0]) } else { -1 }
	return issue_row(item, if i >= 0 { advs[i] } else { []string{} }, w)
}

fn issue_row(item []string, a []string, w int) string {
	if item.len < 5 {
		return clip_line(item.join(' '), line_width(w))
	}
	mark := if a.len < 5 { term.dim('${'-':-20}') } else { color(a[1], '${a[0]:-20}') }
	line := if w < 40 { '#${item[1]} ${item[4]}' } else if w < 80 {
		'#${item[1]} ${item[2]} ${item[3]} ${item[4]}'
	} else { '${'#' + item[1]:-8} ${item[2]:-5} ${item[3]:-7} ${mark} ${item[4]}' }
	return clip_line(line, line_width(w))
}

fn row(r []string, w int) string {
	if r.len < 5 {
		return clip_line(r.join(' '), line_width(w))
	}
	summary := if r.len > 7 && r[7] != '' { '[${r[7]}] ' + r[4] } else { r[4] }
	fixed := if w >= 500 { fixed_in(r) } else { table_cell(fixed_in(r), 14) }
	cve := if w >= 500 { r[2] } else { table_cell(r[2], 15) }
	released := table_cell(release_icon(release_state(r)), 7)
	line := if w < 40 { summary } else if w < 80 {
		'${severity_icon(r[3])} ${r[0]} ${color(r[1], r[1])} ${summary}'
	} else if w < 120 {
		'${severity_icon(r[3])} ${r[0]:-20} ${color(r[1], '${r[1]:-10}')} ${fixed:-14} ${released} ${summary}'
	} else {
		'${severity_icon(r[3])} ${r[0]:-20} ${color(r[1], '${r[1]:-10}')} ${cve:-15} ${r[3]:-9} ${fixed:-14} ${released} ${summary}'
	}
	return clip_line(line, line_width(w))
}

fn table_cell(text string, width int) string {
	plain := term.strip_ansi(clip_line(text, text.len))
	mut clipped := clip_line(plain, width)
	if clipped != plain { clipped = clip_line(plain, width - 1) + '…' }
	mut used := 0
	for g in clipped.graphemes() { used += cell_width(g) }
	return clipped + ' '.repeat(int_max(0, width - used))
}

fn advisory_columns(w int) string {
	if w < 40 { return 'SUMMARY' }
	if w < 80 { return '   ADVISORY STATE SUMMARY' }
	metadata := if w < 120 { '' } else { '${'CVE':-15} ${'SEVERITY':-9} ' }
	return '   ${'ADVISORY':-20} ${'STATE':-10} ${metadata}${'FIXED IN':-14} RELEASE SUMMARY'
}

// Suggested actions depend on the advisory lifecycle, independently of CVE assignment.
fn advisory_actions(a []string) []string {
	if a.len < 5 {
		return []string{}
	}
	mut actions := []string{}
	if a[1] in ['draft', 'published'] && a[2] == '-' {
		actions << 'c request CVE'
	}
	if a[1] == 'triage' {
		actions << 'd accept as draft'
	} else if a[1] == 'closed' {
		actions << 'd reopen as draft'
	}
	if a[1] == 'draft' {
		actions << 'p publish'
	}
	if a[1] in ['triage', 'draft'] {
		actions << 'x close'
	}
	return actions
}

fn key_hints(items []string, width int) string {
	mut out := ''
	mut used := 0
	for item in items {
		space := if used == 0 { '' } else { ' ' }
		if used + space.len + term.printable_len(item) > width {
			break
		}
		out += space + term.bold(term.cyan(item.all_before(' '))) + ' ' +
			term.dim(item.all_after_first(' '))
		used += space.len + term.printable_len(item)
	}
	return out
}

// Catch SIGINT while the CLI child handles the operation. Unlike SIG_IGN, a caught
// handler resets on exec, so the child and its AI/editor still receive Ctrl+C.
fn wait_for_workflow(_ os.Signal) {}

fn tui_workflow(api Repository, args ...string) ! {
	terminal := os.exec(['stty', '-g'])
	if terminal.exit_code != 0 { return error('workflow requires an interactive terminal') }
	previous := os.signal_opt(.int, wait_for_workflow)!
	defer { os.signal_opt(.int, previous) or {} }
	code := os.system_args([os.executable(), '--provider', api.provider, '-r', api.url(), ...args])
	// An interrupted editor may leave echo/canonical input disabled.
	os.system_args(['stty', terminal.output.trim_space()])
	if code == 130 {
		return error_with_code('cancelled; recovery files, if created, are at the path printed above', 130)
	}
	if code != 0 { eprintln('Workflow exited with status ${code}') }
}

// A cancellable line prompt, with the same key handling as the TUI forms.
fn action_input(prompt string) ?string {
	terminal := os.exec(['stty', '-g'])
	if terminal.exit_code != 0 { return none }
	os.system_args(['stty', '-icanon', '-echo', '-isig', 'min', '0', 'time', '2'])
	defer {
		os.system_args(['stty', terminal.output.trim_space()])
		println('')
	}
	mut text := ''
	for {
		w, h := terminal_size()
		runes := text.runes()
		line := input_line(prompt, text, line_width(w))
		print('\x1b[?7l\r${line}\x1b[K\x1b[?7h')
		os.flush()
		k := key(w, h)
		match k {
			'\x1b', '\x03', '\x04' { return none }
			'\n', '\r' { return text }
			'\x15' { text = '' }
			'\x7f', '\x08' {
				text = runes#[..runes.len - 1].string()
			}
			else {
				if k != '' && k[0] >= 0x20 && k[0] != 0x7f { text += k }
			}
		}
	}
	return none
}

// Interactive actions start in cooked mode; input is a commit or URL.
fn run(k string, api Repository, id string, input string) ! {
	match k {
		'C' {
			credits_tui(api, id)!
		}
		'e' {
			advisory_tui(api, id, k)!
		}
		'r' {
			if input == '' { advisory_tui(api, id, k)!; return }
			ctx := action_input('Review source with AI. Extra context (optional; Esc cancels): ') or { return }
			tui_workflow(api, 'review', input, ctx)!
			action_input('Press Enter to return (Ctrl+C/Esc also returns): ') or {}
		}
		'M' {
			tui_workflow(api, 'comment', input)!
			action_input('Press Enter to return (Ctrl+C/Esc also returns): ') or {}
		}
		'b' {
			if input == '' {
				advisory_tui(api, id, k)!
			} else {
				if !similar_tui(api, input)! { return }
				action_input('Press Enter to return (Ctrl+C/Esc also returns): ') or {}
			}
		}
		'n' {
			args := if input != '' {
				input
			} else {
				action_input('commit or issue/PR URL [context] (Ctrl+C/Esc cancels): ') or { return }
			}
			trimmed := args.trim_space()
			if trimmed != '' {
				ctx := if trimmed.contains(' ') { trimmed.all_after_first(' ') } else { '' }
				tui_workflow(api, 'new', trimmed.all_before(' '), ctx)!
				action_input('Press Enter to return (Ctrl+C/Esc also returns): ') or {}
			}
		}
		else {
			if input == '' {
				advisory_tui(api, id, 'v')!
				return
			}
			if input != '' && !input.starts_with('https://') {
				os.system_args(['git', 'show', input])
				return
			}
			view_text(api.source_text(api.source(input)!, false)!)!
		}
	}
}

fn similar_tui(api Repository, input string) !bool {
	println('Find similar bugs with AI using ${input} as a template; results open as a saved report.')
	println('Example: Look for the same missing bounds check in related parsers and callers.')
	println('Enter to search; Ctrl+C or Esc to cancel. Ctrl+C also cancels the running AI.')
	ctx := action_input('extra context (optional): ') or { return false }
	tui_workflow(api, 'similar', input, ctx)!
	return true
}

// Stay on the same advisory while viewing, editing, reviewing and finding related bugs.
fn advisory_tui(api Repository, id string, first string) ! {
	mut action := first
	for {
		match action {
			'v' { view_text(api.advisory(id)!)! }
			'e' { tui_workflow(api, 'edit', id)! }
			'b' { if !similar_tui(api, id)! { return } }
			'r' {
				println('Review ${id} with AI, then inspect its proposed changes in \$EDITOR.')
				println('Example: Check the affected versions and whether the fix addresses the root cause.')
				println('Enter to review; Ctrl+C or Esc to cancel. Ctrl+C also cancels the running AI.')
				ctx := action_input('extra context (optional): ') or { return }
				tui_workflow(api, 'review', id, ctx)!
			}
			else {}
		}
		action = action_input('[v]iew advisory, [r] AI review, [b] similar bugs, [e]dit. Press Enter to return: ') or { return }
		if action !in ['v', 'r', 'b', 'e'] { return }
	}
}

fn view_text(text string) ! {
	path := os.join_path(os.temp_dir(), 'gsadv-view-${os.getpid()}.md')
	os.write_file(path, text)!
	defer { os.rm(path) or {} }
	if os.exists_in_system_path('r2') {
		os.system_args(['r2', '-q', '-c', "cat -m ${path}~..", '--'])
	} else {
		sh('${os.getenv_opt('PAGER') or { 'less' }} "\$1"', path)
	}
}

fn act(k string, api Repository, id string) !string {
	match k {
		'a', 'c' { return api.request_cve(id) }
		'd' { api.set_state(id, if api.provider == 'gitlab' { 'opened' } else { 'draft' })! }
		'p' { api.set_state(id, 'published')! }
		'x' { api.set_state(id, 'closed')! }
		else { return error('unknown action: ${k}') }
	}
	return 'advisory updated; press s for status'
}

// Poll one event against the painted size, including resizes during rendering.
fn key(w int, h int) string {
	for {
		s := poll_key()
		if s != '' { return s }
		nw, nh := terminal_size()
		if nw != w || nh != h { return '' }
	}
	return ''
}

// A terminal read timeout also wakes the list to collect background results.
fn poll_key() string {
	for {
		mut s, _ := os.fd_read(0, 1)
		if s == '\x1b' {
			// Read one complete escape sequence, leaving queued events for the next call.
			for s.len < 64 {
				c, _ := os.fd_read(0, 1)
				if c == '' {
					break
				}
				s += c
				if s in ['\x1b[', '\x1bO'] {
					continue
				}
				if s.starts_with('\x1b[M') {
					// Legacy mouse reports have three bytes after CSI M.
					if s.len < 6 {
						continue
					}
				} else if s.starts_with('\x1b[') && (c[0] < 0x40 || c[0] > 0x7e) {
					continue
				}
				break
			}
		}
		if s.starts_with('\x1b[<') || s.starts_with('\x1b[M') {
			mut button := -1
			if s.starts_with('\x1b[M') && s.len == 6 {
				button = int(s[3]) - 32
			} else if s.starts_with('\x1b[<') && s.ends_with('M') {
				fields := s[3..s.len - 1].split(';')
				if fields.len == 3 {
					button = fields[0].int()
				}
			}
			// Ignore clicks, releases and horizontal scrolling; strip Shift/Alt/Ctrl.
			match button & ~28 {
				64 { return 'k' }
				65 { return 'j' }
				else { continue }
			}
		}
		if s != '' {
			if s.len == 1 && s[0] >= 0xc2 && s[0] <= 0xf4 {
				length := if s[0] < 0xe0 { 2 } else if s[0] < 0xf0 { 3 } else { 4 }
				for s.len < length {
					c, _ := os.fd_read(0, 1)
					if c == '' { break }
					s += c
				}
			}
			return s
		}
		return ''
	}
	return ''
}

// These forms stay in raw mode: Escape/Ctrl+C cancels a form, preserving staged edits.
fn tui_input(title string, prompt string, current string, ascii_only bool) ?string {
	print('\x1b[?25h\x1b[?1000l\x1b[?1006l')
	defer { print('\x1b[?25l\x1b[?1000h\x1b[?1006h') }
	mut screen := TuiScreen{}
	mut text := current
	for {
		w, h := terminal_size()
		layout := tui_layout(h, 1, 1)
		line := input_line(prompt, text, line_width(w))
		screen.draw(list_frame(layout, [title], [line],
			['Enter: next   Esc/Ctrl+C: cancel   Ctrl+U: clear']), w, h)
		print('\x1b[${layout.head + 1};${int_min(w, term.printable_len(line) + 1)}H')
		os.flush()
		k := key(w, h)
		match k {
			'\x1b', '\x03', '\x04' { return none }
			'\n', '\r' { return text }
			'\x15' { text = '' }
			'\x7f', '\x08' {
				graphemes := text.graphemes()
				text = graphemes#[..graphemes.len - 1].join('')
			}
			else {
				if k != '' && k[0] >= 0x20 && k[0] != 0x7f {
					if !ascii_only || (k.len == 1 && k[0] < 0x7f && text.len < 80) { text += k }
				}
			}
		}
	}
	return none
}

fn credit_login(current string) ?string {
	login := tui_input('Credit a GitHub user', 'Username: ', current, true)?
	if login.trim_space() == '' { return none }
	return login
}

fn credit_role_picker(current string) ?string {
	mut sel := int_max(0, credit_roles.map(it.typ).index(current))
	mut top := 0
	mut screen := TuiScreen{}
	for {
		w, h := terminal_size()
		layout := tui_layout(h, 2, 2)
		page := layout.page
		top = list_top(top, sel, credit_roles.len, page)
		mut body := []string{}
		for i in top .. int_min(credit_roles.len, top + page) {
			role := credit_roles[i]
			number := if i == 9 { 0 } else { i + 1 }
			line := '${number} ${role.typ:-23} ${role.description}'
			body << if i == sel { term.inverse(line) } else { line }
		}
		screen.draw(list_frame(layout, [term.bold('Available credit roles'), ''], body,
			[credit_roles[sel].description, 'j/k or arrows: move; Enter/1-9/0: select; Esc/Ctrl+C: cancel']), w, h)
		k := key(w, h)
		match k {
			'\x1b', '\x03', 'q' { return none }
			'\n', '\r' { return credit_roles[sel].typ }
			'j', '\x1b[B' { sel = int_min(sel + 1, credit_roles.len - 1) }
			'k', '\x1b[A' { sel = int_max(sel - 1, 0) }
			else {
				if k.len == 1 && k[0].is_digit() {
					i := if k == '0' { 9 } else { k.int() - 1 }
					return credit_roles[i].typ
				}
			}
		}
	}
	return none
}

fn credits_tui(api Repository, id string) ! {
	terminal := os.exec(['stty', '-g'])
	if terminal.exit_code != 0 { return error('credits screen requires an interactive terminal') }
	mut credits := api.credits(id)!
	mut saved := credits.clone()
	// Read Ctrl+C as a key so exiting with unsaved changes offers save/discard/cancel.
	os.system_args(['stty', '-icanon', '-echo', '-isig', 'min', '0', 'time', '2'])
	print(tui_enter)
	defer {
		print(tui_leave)
		os.flush()
		os.system_args(['stty', terminal.output.trim_space()])
	}
	mut sel := 0
	mut top := 0
	mut status := ''
	mut screen := TuiScreen{}
	for {
		w, h := terminal_size()
		width := line_width(w)
		layout := tui_layout(h, 3, 4)
		page := layout.page
		sel = int_min(int_max(0, sel), int_max(0, credits.len - 1))
		top = list_top(top, sel, credits.len, page)
		dirty := credits != saved
		headers := [term.bold('Credits | ${api.repo} | ${id}'),
			'${credits.len} entries' + if dirty { ' | unsaved changes' } else { ' | saved' },
			'${'GITHUB USER':-24} ROLE']
		mut body := []string{}
		for i in top .. int_min(credits.len, top + page) {
			line := if w < 50 { '@${credits[i].login} ${credits[i].typ}' } else {
				'${'@' + credits[i].login:-24} ${credits[i].typ}'
			}
			body << if i == sel { term.inverse(line) } else { line }
		}
		if credits.len == 0 { body << 'No credits yet. Press a to add a person.' }
		description := if credits.len > 0 {
			credit_description(credits[sel].typ)
		} else {
			'One person can have several roles.'
		}
		screen.draw(list_frame(layout, headers, body, [description, status,
			key_hints(['a add', 'e edit', 'd delete', 's save', '? roles', 'q back'], width),
			key_hints(['q back', 'j/k move', 'enter edit', 'u undo all', 'Esc back'], width)]), w, h)
		mut k := key(w, h)
		mut leave := false
		if k == '' { continue }
		status = ''
		if k in ['q', '\x1b', '\x03'] {
			if !dirty { return }
			screen.width = 0
			match tui_dialog('Unsaved credits: [s]ave and exit, [d]iscard, [c]ancel: ') {
				'd' { return }
				's' {
					k = 's'
					leave = true
				}
				else { continue }
			}
		}
		match k {
			'j', '\x1b[B' { sel++ }
			'k', '\x1b[A' { sel-- }
			'J', '\x1b[6~' { sel += 10 }
			'K', '\x1b[5~' { sel -= 10 }
			'?' {
				screen.width = 0
				credit_role_picker('') or {}
			}
			'a', 'e', '\n', '\r' {
				if k != 'a' && credits.len == 0 { continue }
				index := if k == 'a' { -1 } else { sel }
				old := if index < 0 { Credit{} } else { credits[index] }
				screen.width = 0
				login := credit_login(old.login) or { continue }
				typ := credit_role_picker(old.typ) or { continue }
				credits = change_credit(credits, index, Credit{login, typ}) or {
					status = err.msg()
					continue
				}
				if index < 0 { sel = credits.len - 1 }
				status = 'Credit staged; press s to save to GitHub.'
			}
			'd', 'x' {
				if credits.len > 0 {
					credits.delete(sel)
					status = 'Credit removed locally; s saves, u undoes all changes.'
				}
			}
			'u' {
				credits = saved.clone()
				status = 'Unsaved changes undone.'
			}
			's' {
				if !dirty {
					status = 'No changes to save.'
					continue
				}
				api.update_credits(id, credits) or {
					status = 'Save failed; edits kept: ' + err.msg().replace('\n', ' ')
					continue
				}
				saved = credits.clone()
				status = 'Credits saved.'
				if leave { return }
			}
			else {}
		}
	}
}

fn tui(initial_api Repository, initial_label string) {
	mut api := initial_api
	mut label := initial_label
	saved := os.exec(['stty', '-g']).output.trim_space()
	raw := fn () {
		os.system_args(['stty', '-icanon', '-echo', '-isig', 'min', '0', 'time', '1'])
		print(tui_enter)
	}
	cooked := fn [saved] () {
		print(tui_leave)
		os.flush()
		os.system_args(['stty', saved])
	}
	defer { cooked() }
	mut advs := [][]string{}
	mut cms := [][]string{}
	mut items := [][]string{}
	mut prs := [][]string{}
	mut git_status := 'loading...'
	mut loader := TuiLoader{}
	action_results := chan TuiActionResult{cap: 1}
	mut pending_action := ''
	mut loaded := [false, false, false, false]
	mut lists := []TuiList{len: 4}
	mut changed := [true, true, true, true]
	mut links := AdvisoryLinks{}
	mut view := 0 // 0 advisories, 1 git, 2 issues, 3 PRs/MRs
	mut sel := [0, 0, 0, 0]
	mut top := [0, 0, 0, 0]
	mut status := ''
	mut invalid := map[string]string{}
	if api.repo != '' {
		invalid = api.invalid_marks() or { status = 'local invalid tags: ${err}'; map[string]string{} }
	}
	mut state_filters := [0, 0, 0, 0]
	mut queries := ['', '', '', '']
	mut grep := commit_grep()
	mut screen := TuiScreen{}
	raw()
	loader.request(api, label, .commits, false)
	loader.request(api, label, .git_status, false)
	if api.repo == '' {
		loader.request(api, label, .repository, false)
	} else {
		loader.request(api, label, .advisories, false)
		loader.request(api, label, .issues, false)
	}
	for {
		mut completed := TuiActionResult{}
		if action_results.try_pop(mut completed) == .success {
			pending_action = ''
			status = completed.message
			if status.starts_with('CVE request accepted;') || status.starts_with('advisory updated;') {
				// Apply confirmed changes by ID even if the subsequent refresh fails.
				for mut a in advs {
					if a.len >= 5 && a[0] == completed.id {
						match completed.key {
							'a', 'c' { a[2] = 'requested*' }
							'd' { a[1] = if api.provider == 'gitlab' { 'opened' } else { 'draft' } }
							'p' { a[1] = 'published' }
							'x' { a[1] = 'closed' }
							else {}
						}
					}
				}
				changed = [true, true, true, true]
				if status.starts_with('CVE request accepted;') {
					status = 'CVE request accepted; assignment is asynchronous. g reload, s status'
				}
			}
			loader.request(api, label, .advisories, true)
		}
		for {
			result := loader.poll(api, label) or { break }
			// A late load failure must not hide an action result or cancellation.
			if result.error != '' && status == '' {
				status = '${result.kind}: ' + result.error.replace('\n', ' ')
				if result.kind == .repository { status += '; use -r owner/repo or GSADV_REPO, g retries' }
			}
			match result.kind {
				.repository {
					if result.error == '' && result.text != '' {
						api = result.repository
						state_filters = [0, 0, 0, 0]
						invalid = api.invalid_marks() or { status = 'local invalid tags: ${err}'; map[string]string{} }
						changed = [true, true, true, true]
						loader.request(api, label, .advisories, false)
						loader.request(api, label, .issues, false)
					}
				}
				.advisories {
					if result.error == '' && result.rows != advs {
						advs = result.rows
						links = advisory_links(advs)
						changed = [true, true, true, true]
					} else if result.error != '' && !loaded[0] {
						advs = [['error:', result.error]]
						changed[0] = true
					}
					loaded[0] = true
				}
				.commits {
					if result.error == '' && result.rows != cms {
						cms, changed[1] = result.rows, true
					} else if result.error != '' && !loaded[1] {
						cms, changed[1] = [['error:', result.error]], true
					}
					loaded[1] = true
				}
				.issues {
					// Populate a new filter progressively; keep an existing snapshot
					// and its selection intact until a full refresh succeeds.
					if result.error == '' && (!loaded[2] || !result.more) {
						issues := result.rows.filter(it.len >= 5 && it[2] == 'issue')
						pulls := result.rows.filter(it.len >= 5 && it[2] in ['PR', 'MR'])
						if issues != items { items, changed[2] = issues.clone(), true }
						if pulls != prs { prs, changed[3] = pulls.clone(), true }
					} else if result.error != '' && !loaded[2] && items.len == 0 && prs.len == 0 {
						items = [['error:', result.error]]
						prs = items.clone()
						changed[2], changed[3] = true, true
					}
					if !result.more { loaded[2], loaded[3] = true, true }
				}
				.git_status { git_status = result.text }
			}
		}
		filters := api.tui_states(view)
		w, h := terminal_size()
		width := line_width(w)
		layout := tui_layout(h, 3, 3)
		entries_by_view := [advs, cms, items, prs]
		for v, entries in entries_by_view {
			if changed[v] {
				lists[v].rebuild(entries, advs, links, v)
				lists[v].mark_invalid(entries, invalid)
				changed[v] = false
			}
			lists[v].filter(entries, queries[v], api.tui_states(v)[state_filters[v]])
		}
		visible := lists.map(it.visible)
		advisory_matches := lists[0].matches
		page := layout.page
		n := visible[view].len
		sel[view] = if n == 0 { 0 } else { int_min(int_max(sel[view], 0), n - 1) }
		top[view] = list_top(top[view], sel[view], n, page)
		selected := if n > 0 { visible[view][sel[view]] } else { -1 }
		active_entries := entries_by_view[view]
		input := if view > 0 && selected >= 0 && active_entries[selected].len >= 3 {
			active_entries[selected][0]
		} else { '' }
		ai := if selected >= 0 { lists[view].links[selected] } else { -1 }
		id := if ai >= 0 && ai < advs.len && advs[ai].len >= 5 { advs[ai][0] } else { '' }
		target := if input != '' { input } else { id }
		reason := invalid[invalid_key(target)]
		actions := if id != '' {
			api.actions(advs[ai])
		} else {
			[]string{}
		}
		records_title := if api.provider == 'gitlab' { 'disclosures' } else { 'advisories' }
		prs_title := if api.provider == 'gitlab' { 'MRs' } else { 'PRs' }
		label_hint := if label == '' { 'all labels' } else { 'label: ${label}' }
		issue_hint := if lists[2].state == 'all' { label_hint } else { '${lists[2].state}; ${label_hint}' }
		pr_hint := if lists[3].state == 'all' { label_hint } else { '${lists[3].state}; ${label_hint}' }
		grep_hint := if grep == '' { 'all' } else { 'grep: ${grep}' }
		mut tabs := ['${records_title} ${visible[0].len} (${lists[0].state})', 'commits ${visible[1].len} (${grep_hint})',
			'issues ${visible[2].len} (${issue_hint})', '${prs_title} ${visible[3].len} (${pr_hint})']
		repo_pending := loader.pending[int(TuiLoadKind.repository)]
		for v in 0 .. tabs.len {
			if !loaded[v] { tabs[v] += if v != 1 && api.repo == '' && !repo_pending { ' unavailable' } else { ' loading...' } }
		}
		repo_name := if api.repo != '' { api.repo } else if repo_pending { 'resolving repository...' } else { 'repository unavailable' }
		header := 'gsadv ${api.provider}:${api.host}/${repo_name} | local git: ${git_status}'
		tab_line := tui_tabs(tabs, view, width)
		columns := if view == 0 {
			advisory_columns(w)
		} else if w < 40 {
			if view == 1 { 'SUBJECT' } else { 'NUMBER TITLE' }
		} else if w < 80 {
			if view == 1 { '   COMMIT     SUBJECT' } else { 'NUMBER TYPE STATE TITLE' }
		} else if view == 1 {
			'   ${'COMMIT':-10} ${'DATE':-10} ${'ADVISORY':-20} SUBJECT'
		} else {
			'${'NUMBER':-8} ${'TYPE':-5} ${'STATE':-7} ${'ADVISORY':-20} TITLE'
		}
		mut body := []string{}
		for i in top[view] .. int_min(n, top[view] + page) {
			index := visible[view][i]
			body << lists[view].line(index, active_entries, advs, view, w, i == sel[view])
		}
		if n == 0 {
			body << term.dim(if !loaded[view] && view != 1 && api.repo == '' && !repo_pending {
				'Cannot find repository. Use -r owner/repo or GSADV_REPO; g retries.'
			} else if !loaded[view] {
				'Loading... You can switch tabs or quit while requests run.'
			} else if queries[view] != '' {
				'No matches. Press / to change or clear the text filter.'
			} else if view == 0 {
				'No entries. Press f/F to change the filter or g to reload.'
			} else if view == 1 && grep != '' {
				'No commits match ${grep}. Press l to change the commit filter (empty shows all) or n to enter a commit/URL.'
			} else if view >= 2 {
				'No entries. Press l to change the label filter, f/F for state or g to reload.'
			} else {
				'No entries. Press g to reload or n to enter a commit/URL.'
			})
		}
		hint := if pending_action != '' {
			'Updating ${pending_action}... You can keep browsing; other changes and quitting wait for completion.'
		} else if status != '' {
			status
		} else if reason != '' {
			'invalid (local): ${reason}'
		} else if id != '' {
			cve := match advs[ai][2] {
				'requested*' { 'CVE request recorded locally; g reload, s status' }
				'-' { if api.provider == 'gitlab' { 'no CVE referenced' } else { 'no CVE assigned; request status unknown' } }
				else { if api.provider == 'gitlab' { 'CVE references: ' + advs[ai][2] } else { advs[ai][2] } }
			}
			visibility := if advs[ai].len > 7 && advs[ai][7] != '' { advs[ai][7] + ' | ' } else { '' }
			if view == 0 { release_hint(advs[ai]) + ' | ' } else { '' } + '${id} | ${advs[ai][1]} | ${visibility}${cve}'
		} else {
			'No advisory selected; n creates a draft from a commit, issue or PR'
		}
		filter_hint := if queries[view] == '' { hint } else { '/${queries[view]} | ${hint}' }
		mut headers := [term.bold(header), term.bold(tab_line), term.dim(columns)]
		// Keep the active view visible when a short terminal only has one header.
		if layout.head == 1 { headers[0] = headers[1] }
		credit_hint := if api.provider == 'github' { ['C credits'] } else { []string{} }
		screen.draw(list_frame(layout, headers, body, [filter_hint,
			key_hints(['m actions', 'i invalid', 'I unmark', 'b similar bugs', ...credit_hint, 's status', ...actions, 'g reload', 'A agent'], width),
			key_hints(['? help', 'q quit', 'tab/shift-tab views', '/ text', if view == 1 { 'l grep' } else { 'l label' }, 'f/F state', 'j/k/J/K move',
			'enter view', 'e edit', 'r review', 'M comment', 'n new'], width)]), w, h)
		mut k := ''
		for {
			if loader.results.len > 0 || action_results.len > 0 { break }
			k = poll_key()
			nw, nh := terminal_size()
			if k != '' || nw != w || nh != h { break }
		}
		mut show_input := input
		if k == '' { continue }
		status = ''
		if k == 'm' {
			if target == '' {
				status = 'no item selected'
				continue
			}
			screen.width = 0
			advisory_menu := if id == '' { '' } else {
				actions.join('\n') + '\ns status details\nv view advisory\ne edit advisory\nr AI review\n' + if api.provider == 'github' { 'C manage credits\n' } else { '' }
			}
			source_menu := if input == '' { '' } else { 'r AI review selected source\n' + if view >= 2 { 'M post discussion comment\n' } else { '' } }
			k = tui_dialog('Actions for ${target}\n${hint}\n\n${advisory_menu}' +
				source_menu + 'i mark invalid locally / edit reason\nI remove local invalid tag\nb Find similar bugs\n\nChoose a key; Enter/Esc cancels.')
			if k == 'v' {
				k = '\n'
				show_input = ''
			} else if k !in ['s', 'e', 'r', 'b', 'C', 'M', 'i', 'I'] && !actions.any(it.starts_with(k + ' ')) {
				continue
			}
		}
		if pending_action != '' && k in ['q', '\x03', 'a', 'c', 'd', 'p', 'x', 'e', 'r', 'n', 'C', 'M', 'b', '\n', '\r'] {
			continue
		}
		match k {
			'q', '\x03' {
				break
			}
			'j', '\x1b[B' { sel[view]++ }
			'k', '\x1b[A' { sel[view]-- }
			'J', '\x1b[6~' { sel[view] += 10 }
			'K', '\x1b[5~' { sel[view] -= 10 }
			'\t', '\x1b[Z' {
				// Jump to a linked entry in the destination view when there is one.
				step := if k == '\t' { 1 } else { tabs.len - 1 }
				next := (view + step) % tabs.len
				if next == 0 && ai in advisory_matches {
					if ai !in visible[0] {
						state_filters[0] = 0
						sel[0] = advisory_matches.index(ai)
					} else {
						sel[0] = visible[0].index(ai)
					}
				} else if next != 0 && ai >= 0 {
					entries := entries_by_view[next]
					for c, index in visible[next] {
						entry := entries[index]
						if entry.len >= 3 && adv_of([advs[ai]], entry[0]) == 0 {
							sel[next] = c
							break
						}
					}
				}
				view = next
			}
			'f', 'F' {
				step := if k == 'f' { 1 } else { filters.len - 1 }
				state_filters[view] = (state_filters[view] + step) % filters.len
				sel[view], top[view] = 0, 0
			}
			'/' {
				screen.width = 0
				if query := tui_input('Text filter: Enter applies; empty clears; Esc cancels. Current: ${queries[view]}',
					'Filter text: ', '', false) {
					queries[view] = query.trim_space()
					sel[view], top[view] = 0, 0
				}
			}
			'l' {
				screen.width = 0
				if view == 1 {
					text := tui_input('Commit filter (git log -E --grep). Enter applies; empty shows all commits; Esc cancels.',
						'Grep: ', grep, false) or { continue }
					next_grep := text.trim_space()
					if next_grep == grep { continue }
					grep = next_grep
					os.setenv('GSADV_GREP', grep, true)
					cms, loaded[1], changed[1] = [][]string{}, false, true
					sel[1], top[1] = 0, 0
					loader.request(api, label, .commits, true)
					continue
				}
				if text := tui_input('Label filter for issues and PRs/MRs. Enter applies; empty shows all labels; Esc cancels.',
					'Label: ', label, false) {
					next_label := text.trim_space()
					if next_label == label { continue }
					label = next_label
					// Old rows belong to the previous label, including while reloading.
					items, prs = [][]string{}, [][]string{}
					for v in [2, 3] {
						loaded[v], changed[v] = false, true
						sel[v], top[v] = 0, 0
					}
					if api.repo != '' { loader.request(api, label, .issues, true) }
				}
			}
			'A' {
				// cycle the agent; a custom GSADV_AI is replaced by the presets
				cur := agents.index(setting('AI') or { agents[0] })
				os.setenv('GSADV_AI', agents[(cur + 1) % agents.len], true)
				status = 'agent: ${os.getenv('GSADV_AI')}'
			}
			'g' {
				if api.repo != '' {
					invalid = api.invalid_marks() or { status = 'local invalid tags: ${err}'; invalid.clone() }
					changed = [true, true, true, true]
				}
				loader.request(api, label, .commits, false)
				loader.request(api, label, .git_status, false)
				if api.repo == '' {
					loader.request(api, label, .repository, false)
				} else {
					loader.request(api, label, .advisories, false)
					loader.request(api, label, .issues, false)
				}
			}
			'i', 'I' {
				if api.repo == '' || target == '' {
					status = 'select an item in a loaded repository first'
					continue
				}
				screen.width = 0
				if k == 'i' {
					text := tui_input('Mark ${target} invalid locally. Enter saves; Esc cancels.\nExample: No tagged release shipped vulnerable code.',
						'Reason: ', reason, false) or { continue }
					api.mark_invalid(target, text) or { status = 'error: ${err}'; continue }
					invalid = api.invalid_marks() or { status = 'error: ${err}'; continue }
					status = 'Marked ${target} invalid locally: ${text.trim_space()}'
				} else {
					api.unmark_invalid(target) or { status = 'error: ${err}'; continue }
					invalid = api.invalid_marks() or { status = 'error: ${err}'; continue }
					status = 'Removed local invalid tag from ${target}'
				}
				changed = [true, true, true, true]
			}
			'\n', '\r', 'e', 'r', 'b', 'n', 's', 'C', 'M', '?' {
				if api.repo == '' && k != '?' && !(view == 1 && k in ['\n', '\r']) {
					status = 'Repository unavailable; wait for loading or press g to retry'
					continue
				}
				if k == 'M' && view < 2 { status = 'select an issue/PR/MR to comment'; continue }
				if id == '' && (k in ['e', 's', 'C'] || (k in ['\n', '\r', 'b', 'r', 'M'] && input == '')) {
					status = 'no advisory selected; press n to create a draft'
					continue
				}
				screen.width = 0
				if k == '?' {
					tui_dialog(api.help_text() + '\n\nagent: ${setting('AI') or { agents[0] }}')
					continue
				}
				if k == 'C' && api.provider == 'gitlab' {
					tui_dialog('GitLab credits are text in the disclosure description. Use e to edit attribution.')
					continue
				}
				if k == 's' {
					tui_details(api, id, false, release_hint(advs[ai]))
					continue
				}
				cooked()
				run(k, api, id, if k in ['e', 's', 'C'] { '' } else { show_input }) or {
					if err.code() == 130 {
						status = err.msg()
					} else {
						println('error: ${err}')
						action_input('Press Enter to return (Ctrl+C/Esc also returns): ') or {}
					}
				}
				raw()
				if api.repo != '' { loader.request(api, label, .advisories, true) }
				loader.request(api, label, .git_status, true)
			}
			'a', 'c', 'd', 'p', 'x' {
				if id == '' {
					status = 'no advisory selected'
					continue
				}
				action_key := if k == 'a' { 'c' } else { k }
				if !actions.any(it.starts_with(action_key + ' ')) {
					status = if action_key == 'c' && advs[ai][2] == 'requested*' {
						'CVE request already recorded locally; g reload, s status'
					} else if action_key == 'c' && advs[ai][2] != '-' {
						'CVE already assigned: ${advs[ai][2]}'
					} else {
						'action unavailable for ${advs[ai][1]}; press m for actions'
					}
					continue
				}
				if api.provider == 'gitlab' && action_key == 'c' {
					screen.width = 0
					tui_details(api, id, true, '')
					continue
				}
				verb := match k {
					'a', 'c' { 'request a CVE for' }
					'd' { if api.provider == 'gitlab' { 'reopen' } else { 'accept/reopen as draft' } }
					'p' { 'PUBLISH' }
					else { 'close' }
				}
				screen.width = 0
				if tui_dialog('${verb} ${id}? [y/N] ') == 'y' {
					pending_action = id
					spawn tui_action(api, k, id, action_results)
				}
			}
			else {}
		}
	}
}

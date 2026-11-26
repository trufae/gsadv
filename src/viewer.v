module main

import os
import rand
import term

enum ViewFormat {
	markdown
	advisory
	plain
}

fn view_text(text string, vf ViewFormat) ! {
	if pager := os.getenv_opt('PAGER') {
		if pager.trim_space() != '' {
			dir := os.join_path(os.temp_dir(), 'gsadv-view-${rand.ulid()}')
			os.mkdir(dir, mode: 0o700)!
			path := os.join_path(dir, 'view.md')
			defer {
				os.rm(path) or {}
				os.rmdir(dir) or {}
			}
			os.write_file(path, text)!
			sh('${pager} "\$1"', path)
			return
		}
	}
	if os.is_atty(0) <= 0 || os.is_atty(1) <= 0 || os.getenv('TERM') == 'dumb' {
		print(text)
		return
	}
	state := os.exec(['stty', '-g'])
	if state.exit_code != 0 || os.system_args(['stty', '-icanon', '-echo', '-isig', 'min', '0',
		'time', '1']) != 0 {
		return error('could not open the document viewer terminal')
	}
	print(tui_enter)
	defer {
		print(tui_leave)
		os.flush()
		os.system_args(['stty', state.output.trim_space()])
	}
	mut doc := DocumentView{}
	doc.set_text(text, vf, true)
	mut screen := TuiScreen{}
	for {
		w, h := terminal_size()
		screen.draw(doc.frame(w, h, false), w, h)
		doc.cursor(w, h)
		if !doc.handle(key(w, h)) { return }
	}
}

fn document_lines(text string, vf ViewFormat) []string {
	mut content := text.replace('\r\n', '\n').replace('\x1b', r'\x1b')
	if vf != .plain && term.can_show_color_on_stdout() && os.getenv('NO_COLOR') == '' {
		// The editable advisory format uses --- directly after its metadata.
		if vf == .advisory && content.all_before('\n---\n').split_into_lines().any(it.starts_with('summary:')) {
			content = content.replace_once('\n---\n', '\n\n---\n')
		}
		content = color_markdown(content)
	}
	return content.trim_right('\n').split('\n')
}

struct DocumentRow {
	line   int
	offset int
	text   string
}

// Wrap by terminal cells and track where each row starts in the unwrapped line.
// The Markdown renderer emits SGR spans with a full reset after each span.
fn wrap_document(lines []string, width int) []DocumentRow {
	mut rows := []DocumentRow{cap: lines.len}
	for number, line in lines {
		mut part := ''
		mut style := ''
		mut start := 0
		mut offset := 0
		mut cells := 0
		mut i := 0
		for i < line.len {
			if line[i] == 0x1b {
				end := line.index_after('m', i) or { break }
				code := line[i..end + 1]
				style = if code == '\x1b[0m' { '' } else { code }
				part += code
				i = end + 1
				continue
			}
			end := line.index_after('\x1b', i) or { line.len }
			for character in line[i..end].graphemes() {
				char_width := cell_width(character)
				if cells + char_width > width && cells > 0 {
					rows << DocumentRow{number, start, part}
					part, start, cells = style, offset, 0
				}
				part += if char_width > width { '?' } else { character }
				cells += int_min(char_width, width)
				offset++
			}
			i = end
		}
		rows << DocumentRow{number, start, part}
	}
	return rows
}

struct DocumentView {
mut:
	text     string
	lines    []string
	rows     []DocumentRow
	width    int
	page     int
	anchor   DocumentRow
	top      int
	can_save bool
	entering bool
	cmd      string
	status   string
}

fn (mut doc DocumentView) set_text(text string, vf ViewFormat, can_save bool) {
	doc.text = text
	doc.lines = document_lines(text, vf)
	doc.width = 0
	doc.anchor = DocumentRow{}
	doc.top = 0
	doc.can_save = can_save
}

fn (mut doc DocumentView) frame(w int, h int, split bool) []string {
	width := int_max(1, line_width(w))
	if width != doc.width {
		doc.rows = wrap_document(doc.lines, width)
		doc.width = width
		for i, row in doc.rows {
			if row.line > doc.anchor.line || (row.line == doc.anchor.line && row.offset > doc.anchor.offset) {
				break
			}
			doc.top = i
		}
	}
	doc.page = if h > 1 || doc.entering { h - 1 } else { 1 }
	mut frame := []string{len: h}
	for i in 0 .. int_min(doc.page, doc.rows.len - doc.top) {
		frame[i] = doc.rows[doc.top + i].text
	}
	if h > 1 || doc.entering {
		frame[h - 1] = if doc.entering {
			input_line(':', doc.cmd, width)
		} else if doc.status != '' {
			doc.status
		} else {
			pos := '${doc.rows[doc.top].line + 1}/${doc.lines.len}'
			mut hints := ['↑/↓ scroll']
			if split { hints << 'n/p next/prev' }
			if doc.can_save { hints << ':w <path> save' }
			hints << 'q close'
			term.dim(pos) + '  ' + key_hints(hints, width - pos.len - 2)
		}
	}
	return frame
}

fn (doc DocumentView) cursor(w int, h int) {
	if doc.entering {
		footer := input_line(':', doc.cmd, doc.width)
		print('\x1b[${h};${int_min(w, term.printable_len(footer) + 1)}H')
		os.flush()
	}
}

// Return false when the document should close.
fn (mut doc DocumentView) handle(k string) bool {
	if k == '' { return true }
	if doc.entering { return doc.command_key(k) }
	doc.status = ''
	previous := doc.top
	page := int_max(1, doc.page)
	last := int_max(0, doc.rows.len - page)
	match k {
		'q', '\x1b', '\x03', '\x04' { return false }
		'j', '\x1b[B' { doc.top = int_max(doc.top, int_min(last, doc.top + 1)) }
		'k', '\x1b[A' { doc.top = int_max(0, doc.top - 1) }
		'J', 'l', ' ', '\x1b[6~', '\x1b[C' {
			doc.top = int_max(doc.top, int_min(last, doc.top + page))
		}
		'K', 'h', 'b', '\x1b[5~', '\x1b[D' { doc.top = int_max(0, doc.top - page) }
		'g', '\x1b[H', '\x1bOH', '\x1b[1~' { doc.top = 0 }
		'G', '\x1b[F', '\x1bOF', '\x1b[4~' { doc.top = last }
		':' {
			doc.cmd = ''
			doc.entering = true
			print('\x1b[?25h\x1b[?1000l\x1b[?1006l')
		}
		else {}
	}
	if doc.top != previous { doc.anchor = doc.rows[doc.top] }
	return true
}

fn (mut doc DocumentView) command_key(k string) bool {
	match k {
		'\x1b', '\x03', '\x04' { doc.entering = false }
		'\n', '\r' {
			doc.entering = false
			cmd := doc.cmd.trim_space()
			verb := cmd.fields()[0] or { '' }
			match verb {
				'q' {
					print('\x1b[?25l\x1b[?1000h\x1b[?1006h')
					return false
				}
				'w' {
					path := cmd[verb.len..].trim_space()
					if path == '' {
						doc.status = 'Usage: :w <path>'
					} else if doc.can_save {
						doc.status = 'Saved ${path}'
						save_document(doc.text, path) or { doc.status = 'Save failed: ${err}' }
					} else {
						doc.status = 'No document to save'
					}
				}
				'' {}
				else { doc.status = 'Use :w <path> to save or :q to close' }
			}
		}
		'\x15' { doc.cmd = '' }
		'\x7f', '\x08' {
			chars := doc.cmd.graphemes()
			doc.cmd = chars#[..chars.len - 1].join('')
		}
		else {
			if k[0] >= 0x20 { doc.cmd += k }
		}
	}
	if !doc.entering { print('\x1b[?25l\x1b[?1000h\x1b[?1006h') }
	return true
}

fn save_document(text string, destination string) ! {
	path := os.expand_tilde_to_home(destination)
	// Stage on the destination filesystem so publishing the copy is atomic and exclusive.
	dir := os.join_path(os.dir(path), '.gsadv-view-${rand.ulid()}')
	os.mkdir(dir, mode: 0o700)!
	staged := os.join_path(dir, 'document')
	defer {
		os.rm(staged) or {}
		os.rmdir(dir) or {}
	}
	mut file := os.open_file(staged, 'wb', 0o600)!
	file.write_string(text) or {
		file.close()
		return err
	}
	file.close()
	if os.file_size(staged) != u64(text.len) {
		return error('could not write the complete document')
	}
	os.link(staged, path)!
}

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
	document_viewer(text, document_lines(text, vf))
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

fn document_viewer(text string, lines []string) {
	mut screen := TuiScreen{}
	mut rows := []DocumentRow{}
	mut wrapped_width := 0
	mut anchor := DocumentRow{}
	mut top := 0
	mut entering := false
	mut command := ''
	mut status := ''
	for {
		w, h := terminal_size()
		width := int_max(1, line_width(w))
		if width != wrapped_width {
			rows = wrap_document(lines, width)
			wrapped_width = width
			for i, row in rows {
				if row.line > anchor.line || (row.line == anchor.line && row.offset > anchor.offset) {
					break
				}
				top = i
			}
		}
		page := if h > 1 || entering { h - 1 } else { 1 }
		last := int_max(0, rows.len - int_max(1, page))
		mut frame := []string{len: h}
		for i in 0 .. int_min(page, rows.len - top) {
			frame[i] = rows[top + i].text
		}
		footer := if entering {
			input_line(':', command, width)
		} else if status != '' {
			status
		} else {
			position := '${rows[top].line + 1}/${lines.len}'
			term.dim(position) + '  ' + key_hints(['↑/↓ scroll', ':w <path> save', 'q close'],
				width - position.len - 2)
		}
		if h > 1 || entering { frame[h - 1] = footer }
		screen.draw(frame, w, h)
		if entering {
			print('\x1b[${h};${int_min(w, term.printable_len(footer) + 1)}H')
			os.flush()
		}
		k := key(w, h)
		if k == '' { continue }
		if entering {
			match k {
				'\x1b', '\x03', '\x04' { entering = false }
				'\n', '\r' {
					entering = false
					verb := command.trim_space().fields()[0] or { '' }
					match verb {
						'q' { return }
						'w' {
							path := command.trim_space().all_after_first(verb).trim_space()
							if path == '' {
								status = 'Usage: :w <path>'
							} else {
								status = 'Saved ${path}'
								save_document(text, path) or { status = 'Save failed: ${err}' }
							}
						}
						'' {}
						else { status = 'Use :w <path> to save or :q to close' }
					}
				}
				'\x15' { command = '' }
				'\x7f', '\x08' {
					chars := command.graphemes()
					command = chars#[..chars.len - 1].join('')
				}
				else {
					if k[0] >= 0x20 { command += k }
				}
			}
			if !entering { print('\x1b[?25l\x1b[?1000h\x1b[?1006h') }
			continue
		}
		status = ''
		previous := top
		match k {
			'q', '\x1b', '\x03', '\x04' { return }
			'j', '\x1b[B' { top = int_max(top, int_min(last, top + 1)) }
			'k', '\x1b[A' { top = int_max(0, top - 1) }
			'J', ' ', '\x1b[6~' { top = int_max(top, int_min(last, top + int_max(1, page))) }
			'K', 'b', '\x1b[5~' { top = int_max(0, top - int_max(1, page)) }
			'g', '\x1b[H', '\x1bOH', '\x1b[1~' { top = 0 }
			'G', '\x1b[F', '\x1bOF', '\x1b[4~' { top = last }
			':' {
				command = ''
				entering = true
				print('\x1b[?25h\x1b[?1000l\x1b[?1006l')
			}
			else {}
		}
		if top != previous { anchor = rows[top] }
	}
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

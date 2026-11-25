module main

import os
import term

const settings_file = '.gsadv.ini'

struct ProjectSetting {
	key         string
	value       string // default
	description string
}

const project_settings = [
	ProjectSetting{'grep', '##(crash|security|vulnerability|sandbox)', 'commits tab: git log -E --grep regex; empty shows all commits'},
	ProjectSetting{'label', 'cve', 'issues and PRs/MRs tabs: label filter; empty shows all labels'},
	ProjectSetting{'antfind', 'ANTFIND', 'directory searched for REPORT.md files, relative to the project root'},
	ProjectSetting{'attic', 'Attic', 'directory name (or path below antfind) skipped by the Reports tab; empty skips nothing'},
]

// Per-project settings live next to the checkout, or the cwd outside Git.
fn project_root() string {
	r := os.exec(['git', 'rev-parse', '--show-toplevel'])
	root := r.output.trim_space()
	return if r.exit_code == 0 && root != '' { root } else { os.getwd() }
}

fn settings_path() string {
	return os.join_path(project_root(), settings_file)
}

fn ini_key(line string) string {
	t := line.trim_space()
	if t == '' || t[0] in [`#`, `;`, `[`] || !t.contains('=') { return '' }
	return t.all_before('=').trim_space().to_lower()
}

fn parse_ini(text string) map[string]string {
	mut values := map[string]string{}
	for line in text.split_into_lines() {
		k := ini_key(line)
		if k != '' { values[k] = line.all_after_first('=').trim_space() }
	}
	return values
}

fn project_ini() map[string]string {
	return parse_ini(os.read_file(settings_path()) or { '' })
}

// Replace or remove a key in place, keeping comments and the order of other keys.
fn set_ini(text string, key string, value ?string) string {
	mut lines := []string{}
	mut found := false
	for line in text.split_into_lines() {
		if ini_key(line) != key {
			lines << line
		} else if v := value {
			if !found { lines << '${key}=${v}' }
			found = true
		}
	}
	if v := value {
		if !found { lines << '${key}=${v}' }
	}
	return if lines.len == 0 { '' } else { lines.join('\n') + '\n' }
}

fn project_setting(key string) string {
	if value := setting(key.to_upper()) { return value }
	return project_settings.filter(it.key == key).map(it.value)[0] or { '' }
}

// Edit .gsadv.ini in place and return the keys saved. Keys in live show and
// receive the value the session uses, which may come from flags or the environment.
fn settings_tui(mut live map[string]string) []string {
	path := settings_path()
	mut sel := 0
	mut top := 0
	mut status := ''
	mut saved := []string{}
	mut screen := TuiScreen{}
	for {
		values := parse_ini(os.read_file(path) or { '' })
		mut keys := project_settings.map(it.key)
		for k, _ in values {
			if k !in keys { keys << k }
		}
		w, h := terminal_size()
		width := line_width(w)
		layout := tui_layout(h, 2, 3)
		sel = int_min(int_max(0, sel), keys.len - 1)
		top = list_top(top, sel, keys.len, layout.page)
		mut body := []string{}
		for i in top .. int_min(keys.len, top + layout.page) {
			k := keys[i]
			stored := values[k] or { project_settings.filter(it.key == k).map(it.value)[0] or { '' } }
			value := live[k] or { stored }
			mut line := '${k}=${value}'
			if k in live && value != stored {
				line += term.dim(' (not saved; set by a flag or the environment)')
			} else if k !in live && os.getenv_opt('GSADV_${k.to_upper()}') != none {
				line += term.dim(' (GSADV_${k.to_upper()} overrides)')
			} else if k !in values {
				line += term.dim(' (default)')
			}
			body << clip_line(if i == sel { term.inverse(term.strip_ansi(line)) } else { line }, width)
		}
		info := project_settings.filter(it.key == keys[sel]).map(it.description)[0] or { 'custom setting' }
		screen.draw(list_frame(layout, [term.bold('Settings | ${path}'), ''], body, [info, status,
			key_hints(['j/k move', 'enter edit', 'd reset to default', 'q/Esc back'], width)]), w, h)
		k := key(w, h)
		status = ''
		match k {
			'q', '\x1b', '\x03', ',' { return saved }
			'j', '\x1b[B' { sel++ }
			'k', '\x1b[A' { sel-- }
			'\n', '\r', 'd' {
				name := keys[sel]
				mut value := ?string(none)
				if k != 'd' {
					screen.width = 0
					current := live[name] or { values[name] or { project_setting(name) } }
					value = tui_input('Set ${name} in ${path}. Enter saves; Esc cancels.', '${name}=', current, false) or {
						continue
					}
				}
				text := set_ini(os.read_file(path) or { '' }, name, if v := value { v.trim_space() } else { none })
				os.write_file(path, text) or {
					status = 'error: ${err}'
					continue
				}
				if name in live {
					live[name] = if v := value { v.trim_space() } else {
						project_settings.filter(it.key == name).map(it.value)[0] or { '' }
					}
				}
				if name !in saved { saved << name }
				status = 'Saved ${name}.'
			}
			else {}
		}
	}
	return saved
}

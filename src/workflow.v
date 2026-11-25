module main

import os
import json2
import rand
import time

const agents = ['claude -p', 'codex exec -', 'pmai --progress "\$(cat)"', 'opencode run "\$(cat)"']

// AI prompts live in src/prompts and are embedded at compile time.
const prompt_reply = $embed_file('prompts/reply.txt').to_string().trim_right('\n')
const prompt_gitlab = $embed_file('prompts/gitlab.txt').to_string().trim_right('\n')
const prompt_new = $embed_file('prompts/new.txt').to_string().trim_right('\n')
const prompt_review = $embed_file('prompts/review.txt').to_string().trim_right('\n')
const prompt_source_review = $embed_file('prompts/source_review.txt').to_string().trim_right('\n')
const prompt_similar = $embed_file('prompts/similar.txt').to_string().trim_right('\n')
const prompt_fix = $embed_file('prompts/fix.txt').to_string().trim_right('\n')

// Fill {{name}} placeholders in one pass, so inserted evidence is never expanded.
fn render(template string, values map[string]string) string {
	parts := template.split('{{')
	mut out := parts[0]
	for part in parts[1..] {
		name := part.all_before('}}')
		if part.contains('}}') && name in values {
			out += values[name] + part.all_after_first('}}')
		} else {
			out += '{{' + part
		}
	}
	return out
}

// runs a user configured shell command ($EDITOR, $GSADV_AI..) with $1.. bound to args
fn sh(cmd string, args ...string) int {
	return os.system_args(['sh', '-c', cmd, 'sh', ...args])
}

struct EditSession {
	repo string
	id   string
	kind string
	provider string = 'github'
	host string
	advisory_label string
}

fn C._exit(int)

// Keep each attempt separate, including repeated reviews of the same advisory.
fn start_edit(api Repository, id string, kind string, orig string, prompt string) !string {
	dir := os.join_path(os.temp_dir(), 'gsadv-${rand.ulid()}')
	os.mkdir(dir, mode: 0o700)!
	os.write_file(os.join_path(dir, 'session.json'), json2.encode(EditSession{repo: api.repo, id: id, kind: kind, provider: api.provider, host: api.host, advisory_label: gitlab_advisory_label()}))!
	os.write_file(os.join_path(dir, 'original.md'), orig)!
	os.write_file(os.join_path(dir, 'prompt.txt'), prompt)!
	return dir
}

fn interrupt_edit(_ os.Signal) {
	// The path is printed before starting any work. Avoid allocation in the handler.
	os.fd_write(2, '\nInterrupted. Saved work is in the recovery directory printed above; use gsadv resume to continue.\n')
	C._exit(130)
}

// Files survive aborts, editor failures and API errors. Reports are always kept.
fn resume_edit(dir string, run_ai bool) ! {
	continue_edit(dir, run_ai) or {
		return error('${err}\nResume without AI: gsadv resume ${os.quoted_path(dir)}')
	}
}

fn continue_edit(dir string, run_ai bool) ! {
	session := json2.decode[EditSession](os.read_file(os.join_path(dir, 'session.json'))!)!
	if session.kind !in ['new', 'review', 'edit', 'similar', 'source-review', 'comment', 'fix'] || session.repo == ''
		|| (session.kind != 'new' && session.id == '') {
		return error('invalid recovery session: ${dir}')
	}
	println('Recovery files: ${dir}\nResume without AI: gsadv resume ${os.quoted_path(dir)}')
	os.flush()
	previous := os.signal_opt(.int, interrupt_edit)!
	defer {
		os.signal_opt(.int, previous) or {}
	}
	if session.kind in ['source-review', 'comment'] {
		resume_comment(dir, session, run_ai)!
		return
	}
	if session.kind in ['similar', 'fix'] {
		if run_ai {
			// WIP.txt next to the report shows every gsadv that a fix is running and
			// keeps its log; it stays behind if the run fails or is interrupted.
			wip := if session.kind == 'fix' { start_wip(session.id, dir) } else { '' }
			ask_ai(dir, false, session.kind == 'fix', wip) or { return ai_error(dir, err.msg()) }
		}
		path := os.join_path(dir, 'reply.txt')
		report := os.read_file(path)!
		if report.trim_space() == '' {
			return ai_error(dir, 'empty ${if session.kind == 'fix' { 'fix summary' } else { 'findings report' }}')
		}
		println('${if session.kind == 'fix' { 'Fix summary' } else { 'Findings report' }} saved in ${path}')
		mut outcome := ''
		if session.kind == 'fix' {
			// Keep the agent's summary with the finding; it moves to the attic with it.
			saved := result_path(session.id)
			os.write_file(saved, report) or { eprintln('Could not save ${saved}: ${err}') }
			os.rm(wip_path(session.id)) or {}
			outcome = 'Saved the summary as ${saved}\n' + fix_outcome(session, report)
		} else if is_report(session.id) {
			saved := similar_path(session.id)
			os.write_file(saved, report) or { eprintln('Could not save ${saved}: ${err}') }
			outcome = 'Saved the findings as ${saved}'
		}
		view_text(report)!
		if outcome != '' { println(outcome) }
		return
	}
	orig := os.read_file(os.join_path(dir, 'original.md'))!
	proposed := os.join_path(dir, 'proposed.md')
	if !os.exists(proposed) {
		if session.kind == 'edit' {
			os.write_file(proposed, orig)!
		} else {
			if run_ai {
				ask_ai(dir, true, false, '') or { return ai_error(dir, err.msg()) }
			}
			notes, text := saved_ai_reply(dir) or {
				return ai_error(dir, err.msg())
			}
			head := if orig.starts_with('#') { orig.all_before('\n') + '\n' } else { '' }
			os.write_file(os.join_path(dir, 'notes.txt'), notes)!
			os.write_file(proposed, head + text)!
		}
	}
	if session.kind == 'review' {
		path := os.join_path(dir, 'review.diff')
		if !os.exists(path) {
			notes := os.read_file(os.join_path(dir, 'notes.txt'))!
			diff := udiff(notes, orig, os.read_file(proposed)!)!
			os.write_file(path, diff)!
			if diff == '' && !os.exists(os.join_path(dir, 'edit.md')) {
				println(notes)
				println('No review changes to apply; the server was not updated. Recovery files kept in ${dir}')
				return
			}
		}
	} else if !os.exists(os.join_path(dir, 'edit.md')) {
		notes := if session.kind == 'new' {
			os.read_file(os.join_path(dir, 'notes.txt'))!.split_into_lines().map('# ' + it).join('\n') + '\n'
		} else {
			''
		}
		os.write_file(os.join_path(dir, 'edit.md'), notes + os.read_file(proposed)!)!
	}
	if session.kind == 'review' {
		println('Review ready. Close the editor to apply the remaining changes; empty the file to abort.')
	}
	host := if session.host != '' { session.host } else if os.getenv('GH_HOST') != '' { os.getenv('GH_HOST') } else { 'github.com' }
	api := repository_location('https://${host}/${session.repo}', session.provider, host)!
	if session.advisory_label != '' { os.setenv('GSADV_ADVISORY_LABEL', session.advisory_label, true) }
	for {
		a := edit(dir, orig) or {
			println('No changes saved to the server; recovery files kept in ${dir}')
			return
		}
		if session.kind == 'new' {
			id := api.create_advisory(a) or {
				eprintln('Could not create advisory: ${err}\nEdited text and AI reply are saved in ${dir}')
				if retry_save(dir) { continue }
				return err
			}
			println(id)
		} else {
			api.update_advisory(session.id, a) or {
				eprintln('Could not save ${session.id}: ${err}\nEdited text and AI reply are saved in ${dir}')
				if retry_save(dir) { continue }
				return err
			}
			println('Saved changes to ${session.id} on ${api.provider}.')
		}
		// A resumed directory may also contain files the user added; leave those alone.
		for name in ['session.json', 'prompt.txt', 'reply.txt', 'claude.jsonl', 'notes.txt', 'original.md',
			'proposed.md', 'review.diff', 'result.md', 'edit.md'] {
			os.rm(os.join_path(dir, name)) or {}
		}
		os.rmdir(dir) or { eprintln('Saved; remaining recovery files kept in ${dir}') }
		return
	}
}

fn retry_save(dir string) bool {
	choice := os.input('[e]dit saved result, use [n]ew version, [q]uit and keep files [q]: ').to_lower()
	if choice !in ['e', 'n'] { return false }
	name := if choice == 'n' { 'proposed.md' } else { 'result.md' }
	os.cp(os.join_path(dir, name), os.join_path(dir, 'edit.md')) or {
		eprintln(err)
		return false
	}
	return true
}

// Opens the diff or the manually edited advisory; an empty/unchanged result aborts.
fn edit(dir string, orig string) ?Adv {
	plain := os.join_path(dir, 'edit.md')
	mut path := if os.exists(plain) { plain } else { os.join_path(dir, 'review.diff') }
	mut open_editor := true
	for {
		if open_editor {
			println('Opening ${os.file_name(path)} in ${os.getenv_opt('EDITOR') or { 'vi' }} ...')
			code := sh('${os.getenv_opt('EDITOR') or { 'vi' }} "\$1"', path)
			if code != 0 {
				eprintln('Editor exited with status ${code}; saved work kept in ${dir}')
				return none
			}
		}
		open_editor = true
		text := os.read_file(path) or {
			eprintln(err)
			return none
		}
		if text.trim_space() == '' { return none }
		mut res := text
		mut problem := ''
		if path.ends_with('.diff') {
			res = apply(orig, text) or {
				problem = 'Cannot apply review diff: ${err}\nManual editing will start from the full AI version; original.md and review.diff are preserved.'
				os.read_file(os.join_path(dir, 'proposed.md')) or {
					eprintln(err)
					return none
				}
			}
		}
		os.write_file(os.join_path(dir, 'result.md'), res) or {
			eprintln(err)
			return none
		}
		if problem == '' {
			if res.trim_space() == '' || res == orig { return none }
			if a := parse(res) {
				if original := parse(orig) {
					if advisory_changes(original, a).len == 0 {
						println('No advisory fields changed; the server was not updated.')
						return none
					}
				}
				return a
			} else {
				problem = 'Invalid advisory: ${err}'
			}
		}
		eprintln('${problem}\nWork is saved in ${dir}')
		if !path.ends_with('.diff') {
			choice := os.input_opt('Edit again? [Y/n] ') or { return none }
			if choice.to_lower() == 'n' { return none }
			continue
		}
		choice := os.input('Retry [d]iff, use [n]ew AI version, [m]anually edit result, [q]uit and keep files [q]: ').to_lower()
		match choice {
			'd' { continue }
			'n', 'm' {
				if choice == 'n' {
					res = os.read_file(os.join_path(dir, 'proposed.md')) or {
						eprintln(err)
						return none
					}
				}
				os.write_file(plain, res) or {
					eprintln(err)
					return none
				}
				path = plain
				open_editor = choice == 'm'
			}
			else { return none }
		}
	}
	return none
}

fn format_elapsed(seconds int) string {
	hours := seconds / 3600
	minutes := seconds % 3600 / 60
	remaining_seconds := seconds % 60
	if hours > 0 {
		return '${hours}h ${minutes}m ${remaining_seconds}s'
	}
	if minutes > 0 {
		return '${minutes}m ${remaining_seconds}s'
	}
	return '${remaining_seconds}s'
}

// Keep stdout on disk from the start so interruption cannot discard pipe buffers.
// stderr is inherited; Claude's structured stdout needs a separate progress reader.
// edits lets the default Claude preset change files; custom GSADV_AI commands set their own permissions.
// tee, when set, receives a copy of the agent's progress and output as it streams.
fn ask_ai(dir string, advisory bool, edits bool, tee string) ! {
	pf := os.join_path(dir, 'prompt.txt')
	of := os.join_path(dir, 'reply.txt')
	ai := setting('AI') or { agents[0] }
	claude := ai == agents[0]
	permission := if edits { ' --permission-mode acceptEdits' } else { '' }
	command := if claude { '${ai}${permission} --output-format stream-json --verbose' } else { ai }
	log := if claude { os.join_path(dir, 'claude.jsonl') } else { of }
	os.write_file(of, '')!
	if claude { os.write_file(log, '')! }
	mut input := os.open(log)!
	defer { input.close() }
	mut process := os.new_process('sh')
	process.set_args(['-c', '{ ${command}\n} < "\$1" > "\$2"', 'sh', pf, log])
	mut stream := ClaudeStream{advisory: advisory, tee: tee}
	stream.say('running ${ai} ...')
	mut stopwatch := time.new_stopwatch()
	process.run()
	defer { process.close() }
	mut offset := u64(0)
	mut next_update := 10
	for {
		alive := process.is_alive()
		if claude {
			for {
				data := input.read_bytes_at(8192, offset)
				if data.len == 0 { break }
				offset += u64(data.len)
				stream.feed(data.bytestr(), of, false)
			}
		} else if tee != '' {
			// Other agents write their reply straight to reply.txt; mirror it.
			for {
				data := input.read_bytes_at(8192, offset)
				if data.len == 0 { break }
				offset += u64(data.len)
				append_text(tee, data.bytestr())
			}
		}
		if !alive { break }
		seconds := int(stopwatch.elapsed().seconds())
		if seconds >= next_update {
			stream.say('[gsadv] agent still running (${format_elapsed(seconds)} elapsed)')
			next_update = seconds + 10
		}
		time.sleep(100 * time.millisecond)
	}
	process.wait()
	if claude { stream.feed('', of, true) }
	if process.code != 0 {
		detail := if stream.failure == '' { '' } else { '; ${stream.failure}' }
		return error('agent exited with status ${process.code}${detail}; output saved in ${log}')
	}
	if claude && (stream.failure != '' || !stream.finished) {
		reason := if stream.failure != '' { stream.failure } else if advisory {
			'Claude exited without a final advisory'
		} else { 'Claude exited without a final result' }
		return error('${reason}; event log saved in ${log}')
	}
	seconds := int(stopwatch.elapsed().seconds())
	stream.say('[gsadv] agent finished (${format_elapsed(seconds)} elapsed)')
}

struct ClaudeContent {
	type string
	text string
	name string
	// tool_result content is a string or a list of text blocks.
	content ?json2.Any
	input map[string]json2.Any
}

fn (block ClaudeContent) output() string {
	c := block.content or { return '' }
	if c is string { return c }
	if c is []json2.Any {
		mut parts := []string{}
		for item in c {
			if item is map[string]json2.Any {
				text := item['text'] or { continue }
				if text is string { parts << text }
			}
		}
		return parts.join('\n')
	}
	return json2.encode(c)
}

struct ClaudeMessage {
	content []ClaudeContent
}

struct ClaudeEvent {
	type string
	subtype string
	parent_tool_use_id ?string
	message ClaudeMessage
	result string
	is_error bool
	errors []string
}

struct ClaudeStream {
	advisory bool
	tee      string // also append progress and replies here, e.g. a report's WIP.txt
mut:
	pending string
	finished bool
	failure string
}

// Show the operation without dumping file contents or replacement text. JSON
// quoting preserves multiline commands and keeps terminal controls inert.
fn claude_tool_progress(block ClaudeContent) string {
	mut lines := ['[claude] tool: ${block.name}']
	for key in ['description', 'command', 'file_path', 'notebook_path', 'path', 'pattern',
		'glob', 'url', 'query', 'subagent_type', 'prompt', 'offset', 'limit'] {
		value := block.input[key] or { continue }
		if value is string && value.trim_space() == '' { continue }
		text := json2.encode(value)
		chars := text.runes()
		preview := if chars.len > 1000 { chars[..997].string() + '...' } else { text }
		lines << '  ${key}: ${preview}'
	}
	return lines.join('\n')
}

// JSON lines can span reads, including a split UTF-8 character. Decode only whole lines.
fn (mut stream ClaudeStream) feed(chunk string, output string, eof bool) {
	stream.pending += chunk
	for {
		end := stream.pending.index('\n') or { break }
		line := stream.pending[..end]
		stream.pending = stream.pending[end + 1..]
		stream.event(line, output) or { stream.failure = err.msg() }
	}
	if eof && stream.pending != '' {
		stream.event(stream.pending, output) or { stream.failure = err.msg() }
		stream.pending = ''
	}
}

fn append_text(path string, text string) {
	if path == '' { return }
	mut file := os.open_append(path) or { return }
	file.write_string(text) or {}
	file.close()
}

fn (stream ClaudeStream) say(text string) {
	eprintln(text)
	append_text(stream.tee, text + '\n')
}

fn (mut stream ClaudeStream) event(line string, output string) ! {
	if line.trim_space() == '' { return }
	event := json2.decode[ClaudeEvent](line) or { return error('invalid Claude event: ${err}') }
	match event.type {
		'system' {
			if event.subtype == 'init' { stream.say('[claude] session started') }
		}
		'assistant' {
			for block in event.message.content {
				if block.type == 'text' && block.text != '' {
					if event.parent_tool_use_id == none && !stream.finished {
						mut file := os.open_append(output)!
						file.write_string(block.text + '\n') or { file.close(); return err }
						file.close()
					}
					stream.say(block.text)
				} else if block.type == 'tool_use' {
					stream.say(claude_tool_progress(block))
				}
			}
		}
		'result' {
			// Background tasks can produce another turn after the main reply is complete.
			if event.parent_tool_use_id != none || stream.finished { return }
			if event.is_error {
				return error('Claude failed: ${event.result} ${event.errors.join('; ')}'.trim_space())
			}
			// A waiting turn can finish before a background build returns the advisory.
			os.write_file(output, event.result)!
			if stream.advisory {
				_, _ := ai_reply(event.result) or { return }
			}
			stream.finished = true
		}
		else {}
	}
}

// Agent errors often arrive on stdout, which is captured instead of shown live.
fn ai_error(dir string, reason string) IError {
	path := os.join_path(dir, 'reply.txt')
	out := os.read_file(path) or { '' }
	if out.trim_space() != '' {
		return error('${reason}\nNo changes saved to the server. AI reply (${path}):\n${out#[..2000]}')
	}
	// The transcript still holds what the agent concluded; keep a readable copy.
	log := os.join_path(dir, 'claude.jsonl')
	if os.exists(log) {
		if text := recover_chat(log, RecoverOptions{ last: true }) {
			recovered := os.join_path(dir, 'recovered.md')
			os.write_file(recovered, text) or {}
			return error('${reason}\nNo changes saved to the server. AI reply was empty.\nPartial conversation recovered in ${recovered}\nA final report saved before failing can be extracted with:\n  gsadv recover ${log} --last')
		}
	}
	return error('${reason}\nNo changes saved to the server. AI reply (${path}):\n(empty reply)')
}

const recover_help = 'Usage: gsadv recover <claude.jsonl|recovery-directory> [options]
Turn a Claude stream-json transcript into Markdown, without the tool call boilerplate.
  -o, --output <file>  write the result to a file instead of stdout
  --last               only what follows the last completed run (the interrupted one)
  --all                include the user prompt and thinking blocks
  --tools              include tool calls and their output (default: assistant text only)
  --truncate <n>       bytes of tool output kept per call (default 4000, 0 keeps all)
  --raw                plain text with role prefixes, no Markdown decorations
The transcript records every message, so it recovers what the agent concluded even
when reply.txt is empty. It is partial evidence, never a valid advisory to save.'

struct RecoverOptions {
mut:
	last     bool
	full     bool
	no_tools bool = true
	thinking bool
	raw      bool
	truncate int = 4000
}

fn cmd_recover(args []string) ! {
	mut opts := RecoverOptions{}
	mut log := ''
	mut output := ''
	mut i := 0
	for i < args.len {
		arg := args[i]
		i++
		match arg {
			'-h', '--help' { println(recover_help); return }
			'--last' { opts.last = true }
			'--all' { opts.full = true }
			'--tools' { opts.no_tools = false }
			'--thinking' { opts.thinking = true }
			'--raw' { opts.raw = true }
			'-o', '--output' {
				if i >= args.len { return error('missing value for ${arg}') }
				output = args[i]
				i++
			}
			'--truncate' {
				if i >= args.len { return error('missing value for ${arg}') }
				opts.truncate = args[i].int()
				i++
			}
			else {
				if arg.starts_with('-') { return error('unknown option ${arg}') }
				if log != '' { return error('unexpected argument ${arg}') }
				log = arg
			}
		}
	}
	if log == '' { return error('missing session log\n${recover_help}') }
	// A recovery directory holds the session files next to reply.txt.
	path := if os.is_dir(log) { os.join_path(log, 'claude.jsonl') } else { log }
	text := recover_chat(path, opts)!
	if output != '' {
		os.write_file(output, text)!
		eprintln('recovered ${text.split_into_lines().len} lines in ${output}')
		return
	}
	print(text)
}

struct ChatBlock {
	kind   string // text, thinking, tool or tool output
	text   string
	detail string
}

struct ChatEvent {
	role    string
	blocks  []ChatBlock
	// A result ends a run: ok marks the runs that completed, error ones did not.
	is_done bool
	ok      bool
	reply   bool
	result  string
}

// Decode the messages of a stream-json log, ignoring bookkeeping events.
fn read_chat(path string) ![]ChatEvent {
	if !os.exists(path) { return error('${path} does not exist') }
	mut events := []ChatEvent{}
	// split on newlines so a truncated last line is kept and reported as damaged
	for line in os.read_file(path)!.split_into_lines() {
		if line.trim_space() == '' { continue }
		// json2 accepts truncated objects, so the event type is checked on the result.
		event := json2.decode[ClaudeEvent](line) or {
			events << ChatEvent{
				role: 'error'
				blocks: [ChatBlock{
					kind: 'text'
					text: 'Invalid log line: ${err}'
				}]
			}
			continue
		}
		if event.type == '' {
			events << ChatEvent{
				role: 'error'
				blocks: [ChatBlock{
					kind: 'text'
					text: 'Invalid log line: ${line#[..(if line.len > 80 { 80 } else { line.len })]}'
				}]
			}
			continue
		}
		match event.type {
			'result' {
				// Empty results close a run without adding a reply of their own.
				events << ChatEvent{
					is_done: true
					ok: !event.is_error
					// The final result carries the reply; it replaces the notes so far.
					reply: event.result.trim_space() != '' && !event.is_error
					result: event.result
				}
			}
			'assistant', 'user' {
				role := if event.parent_tool_use_id != none { 'subagent' } else if event.type == 'assistant' {
					'assistant'
				} else {
					'user'
				}
				mut blocks := []ChatBlock{}
				for block in event.message.content {
					match block.type {
						'text' {
							blocks << ChatBlock{
								kind: 'text'
								text: block.text
							}
						}
						'thinking' {
							blocks << ChatBlock{
								kind: 'thinking'
								text: block.text
							}
						}
						'tool_use' {
							blocks << ChatBlock{
								kind: 'tool'
								text: block.name
								detail: claude_tool_detail(block)
							}
						}
						'tool_result' {
							blocks << ChatBlock{
								kind: event.type
								text: block.output()
							}
						}
						else {}
					}
				}
				if blocks.len > 0 { events << ChatEvent{role: role, blocks: blocks} }
			}
			else {}
		}
	}
	return events
}

fn claude_tool_detail(block ClaudeContent) string {
	mut parts := []string{}
	for key in ['description', 'command', 'file_path', 'notebook_path', 'path', 'pattern',
		'glob', 'url', 'query', 'subagent_type', 'offset', 'limit'] {
		value := block.input[key] or { continue }
		mut text := json2.encode(value)
		if value is string && value.trim_space() == '' { continue }
		if text.len > 200 { text = text#[..197] + '...' }
		parts << '${key}=${text}'
	}
	return parts.join(' ')
}

fn truncate_text(text string, limit int) string {
	if limit <= 0 || text.len <= limit { return text }
	return text#[..limit] + '\n... (truncated)'
}

// Tool calls become one line each, so the reply text stays readable; a run whose
// final result never arrived is still recovered as its partial conversation.
fn recover_chat(path string, opts RecoverOptions) !string {
	events := read_chat(path)!
	mut first := 0
	mut last := events.len
	mut failure := ''
	if opts.last {
		// Only an error result marks an interrupted run; a normal reply is not a stop.
		for i := events.len - 1; i >= 0; i-- {
			if events[i].is_done && !events[i].ok && events[i].result.trim_space() != '' {
				failure = events[i].result.trim_space()
				last = i
				break
			}
		}
		// A completed run closes with a reply result followed by an empty one. When that
		// closing pair sits right before the failure, its reply is recovered too.
		for i := last - 1; i >= 0; i-- {
			if events[i].is_done && events[i].ok && events[i].result.trim_space() == '' {
				first = i + 1
				if first >= last && i > 0 && events[i - 1].is_done && events[i - 1].reply {
					first = i - 1
				}
				break
			}
		}
	}
	mut out := []string{}
	if !opts.raw {
		out << '# Recovered conversation'
		out << ''
		out << 'Partial transcript of `${os.file_name(path)}`, without tool call boilerplate.'
		out << if opts.no_tools {
			'Only the agent text is shown; pass --tools to include its tool calls.'
		} else {
			'Tool output may be truncated; incomplete statements are expected.'
		}
		out << ''
	}
	mut tools := 0
	for i := first; i < last; i++ {
		e := events[i]
		if e.is_done {
			// The failure is reported once, as the stop reason below.
			if e.result.trim_space() != '' && e.result.trim_space() != failure {
				out << (if opts.raw { 'Result:' } else { '> **Result:**' }) + ' ${e.result.trim_space()}'
				out << ''
			}
			continue
		}
		mut lines := []string{}
		mut output := []string{}
		for block in e.blocks {
			match block.kind {
				'text' {
					// Damaged lines are reported even when only assistant text is wanted.
					if e.role == 'error' { lines << block.text }
					text := block.text.trim_space()
					// The API repeats a quota or auth failure as assistant text.
					if failure != '' && text.contains(failure) { continue }
					// --raw only drops the Markdown decoration, so it keeps every message.
					if text != '' && (opts.raw || e.role == 'assistant' || opts.full) { lines << text }
				}
				'thinking' {
					if opts.thinking && block.text.trim_space() != '' {
						lines << '_thinking:_ ${block.text.trim_space()}'
					}
				}
				'tool' {
					if opts.no_tools { continue }
					tools++
					detail := if block.detail == '' { '' } else { ': ${block.detail}' }
					mark := if opts.raw { '' } else { '- ' }
					lines << '${mark}`${block.text}`${detail}'
				}
				'user' {
					if opts.no_tools { continue }
					text := truncate_text(block.text.trim_space(), opts.truncate)
					if text != '' { output << text }
				}
				else {}
			}
		}
		if lines.len == 0 && output.len == 0 { continue }
		if lines.len > 0 {
			out << (if opts.raw { '${e.role}:' } else { '### ${e.role}' })
			out << lines.join('\n')
			out << ''
		}
		if output.len > 0 {
			if !opts.raw { out << '```' }
			out << output.join('\n')
			if !opts.raw { out << '```' }
			out << ''
		}
	}
	if failure != '' {
		out << ''
		out << (if opts.raw { 'Stopped:' } else { '> **Stopped:**' }) + ' ${failure}'
	}
	if out.len == 0 { return 'No messages recovered from ${path}; the agent stopped before replying.\n' }
	if !opts.raw && tools > 0 {
		out << ''
		out << '---'
		out << '${tools} tool call(s) summarized. Use --thinking for reasoning, --truncate 0 for full'
		out << 'tool output, or --last to show only the interrupted run.'
	}
	return out.join('\n') + '\n'
}

fn ai_reply(out string) !(string, string) {
	at := if out.starts_with('summary:') {
		0
	} else {
		out.last_index('\nsummary:') or {
			return error('no advisory in saved reply.txt; repair the reply, then resume')
		} + 1
	}
	return out[..at].trim_space(), out[at..]
}

// Older versions could keep a waiting message instead of a later completed advisory.
// Recover only successful top-level results, never tool output or partial messages.
fn saved_ai_reply(dir string) !(string, string) {
	path := os.join_path(dir, 'reply.txt')
	out := os.read_file(path) or { '' }
	if notes, text := ai_reply(out) {
		return notes, text
	}
	log := os.join_path(dir, 'claude.jsonl')
	for line in os.read_lines(log) or { []string{} } {
		event := json2.decode[ClaudeEvent](line) or { continue }
		if event.type != 'result' || event.is_error || event.parent_tool_use_id != none {
			continue
		}
		notes, text := ai_reply(event.result) or { continue }
		parse(text) or { continue }
		os.write_file(path, event.result)!
		eprintln('[gsadv] Recovered completed advisory from ${log}')
		return notes, text
	}
	return ai_reply(out)
}

// unified diff of the whole text, preceded by free text notes
fn udiff(notes string, a string, b string) !string {
	fa := os.join_path(os.temp_dir(), 'gsadv-a-${os.getpid()}')
	fb := fa.replace('-a-', '-b-')
	os.write_file(fa, a)!
	os.write_file(fb, b)!
	defer {
		os.rm(fa) or {}
		os.rm(fb) or {}
	}
	d := os.exec(['diff', '-U', '99999', '-L', 'advisory', '-L', 'review', fa, fb])
	if d.exit_code == 0 { return '' }
	if d.exit_code != 1 { return error('could not generate review diff: ${d.output}') }
	return notes.split_into_lines().map('  ' + it).join('\n') + '\n\n' + d.output
}

// rebuilds the text from an edited full-context diff: removed '+' lines are not added,
// removed '-' lines keep the original line, edited
// context lines replace it, everything before the first @@ is ignored
fn apply(orig string, patch string) !string {
	src := orig.split_into_lines()
	mut out := []string{}
	mut add := []string{} // '+' lines go after the kept originals they replace
	mut i := 0
	mut body := false
	for line, l in patch.split_into_lines() {
		if !body || l == '\\ No newline at end of file' {
			if !body && l.starts_with('@@') {
				range := l.split(' ')
				old := if src.len == 0 {
					'-0,0'
				} else if src.len == 1 {
					'-1'
				} else {
					'-1,${src.len}'
				}
				if range.len < 4 || range[1] != old || range[3] != '@@' {
					return error('line ${line + 1}: expected a full-context diff of the original advisory')
				}
			}
			body = body || l.starts_with('@@')
			continue
		}
		if l == '' || l[0] !in [u8(`+`), `-`, ` `] {
			return error('line ${line + 1}: expected a diff line starting with +, - or a space')
		}
		if l.starts_with('+') {
			add << l[1..]
			continue
		}
		t := l#[1..]
		j := src#[i..].index(t)
		if i >= src.len || (l.starts_with('-') && j < 0) {
			return error('line ${line + 1}: original line not found: ${t}')
		}
		if j > 0 {
			out << src[i..i + j] // their '-' lines were removed
			i += j
		}
		out << add
		add.clear()
		if !l.starts_with('-') {
			out << t // context, or an edited context line replacing src[i]
		}
		i++
	}
	if !body { return error('missing @@ diff header') }
	out << src#[i..]
	out << add
	return out.join('\n') + '\n'
}

fn cmd_new(api Repository, input string, ctx string) ! {
	if input == '' {
		template := advisory_template(api.repo.all_after_last('/'))
		dir := start_edit(api, '', 'new', template, '')!
		os.write_file(os.join_path(dir, 'notes.txt'), '')!
		for name in ['proposed.md', 'edit.md'] {
			os.write_file(os.join_path(dir, name), template)!
		}
		resume_edit(dir, false)!
		return
	}
	s := api.source(input)!
	evidence := api.source_text(s, true)!
	existing := api.advisories('')!.map(it.join(' ')).join('\n')
	finding := finding_context(evidence)
	if finding != '' { eprintln('Using finding ${ant_id(evidence)} from ${reports_base()}') }
	prompt := render(prompt_new, {
		'provider': api.provider
		'repo':     api.repo
		'cli':      api.cli()
		'reply':    api.reply_instructions()
		'url':      s.url
		'ctx':      ctx
		'existing': existing
		'evidence': evidence
		'finding':  finding
	})
	resume_edit(start_edit(api, '', 'new', '', prompt)!, true)!
}

fn cmd_review(api Repository, id string, ctx string) ! {
	orig := api.advisory(id)!
	prompt := render(prompt_review, {
		'provider': api.provider
		'repo':     api.repo
		'cli':      api.cli()
		'reply':    api.reply_instructions()
		'ctx':      ctx
		'advisory': orig
	})
	resume_edit(start_edit(api, id, 'review', orig, prompt)!, true)!
}

fn cmd_source_review(api Repository, input string, ctx string) ! {
	s := api.source(input)!
	evidence := api.source_text(s, true)!
	prompt := render(prompt_source_review, {
		'repo':     api.repo
		'cli':      api.cli()
		'url':      s.url
		'ctx':      ctx
		'evidence': evidence
	})
	resume_edit(start_edit(api, input, 'source-review', evidence, prompt)!, true)!
}

fn cmd_comment(api Repository, input string, text string) ! {
	s := api.source(input)!
	if s.kind == 'commit' { return error('comments require an issue or PR/MR URL') }
	resume_edit(start_edit(api, s.url, 'comment', text, '')!, false)!
}

fn resume_comment(dir string, session EditSession, run_ai bool) ! {
	receipt := os.join_path(dir, 'posted.txt')
	if os.exists(receipt) { println('Comment already posted: ${os.read_file(receipt)!}'); return }
	path := os.join_path(dir, 'edit.md')
	if !os.exists(path) {
		if session.kind == 'source-review' && run_ai {
			ask_ai(dir, false, false, '') or { return ai_error(dir, err.msg()) }
		}
		name := if session.kind == 'comment' { 'original.md' } else { 'reply.txt' }
		os.write_file(path, os.read_file(os.join_path(dir, name))!)!
	}
	if sh('${os.getenv_opt('EDITOR') or { 'vi' }} "\$1"', path) != 0 {
		return error('editor failed; saved text is in ${path}')
	}
	body := os.read_file(path)!.trim_space()
	if body == '' { println('Cancelled; recovery files kept in ${dir}'); return }
	api := repository_location(session.repo, session.provider, session.host)!
	s := api.source(session.id)!
	if s.kind == 'commit' {
		println('Review report saved in ${path}')
		view_text(body)!
		return
	}
	println('\n${body}\n')
	if os.input('Post this comment to ${s.url}? [y/N] ') != 'y' {
		println('Comment saved in ${path}; resume when ready to post.')
		return
	}
	url := api.comment(s, body)!
	os.write_file(receipt, url) or {
		println('Comment posted: ${url}\nCould not save the local posting receipt: ${err}')
		return
	}
	println('Comment posted: ${url}')
}

fn cmd_similar(api Repository, input string, ctx string) ! {
	advs := api.advisories('')!
	mut origin := input
	mut evidence := ''
	if is_report(input) {
		origin = os.real_path(input)
		evidence = os.read_file(origin)!
	} else if api.is_advisory(input) {
		evidence = api.advisory(input)!
	} else {
		s := api.source(input)!
		origin = s.url
		evidence = api.source_text(s, true)!
		linked := adv_of(advs, if s.kind == 'commit' { s.ref } else { s.url })
		if linked >= 0 {
			evidence += '\nLinked advisory:\n' + api.advisory(advs[linked][0])!
		}
	}
	prompt := render(prompt_similar, {
		'repo':     api.repo
		'cli':      api.cli()
		'source':   origin
		'ctx':      ctx
		'existing': advs.map(it.join(' ')).join('\n')
		'evidence': evidence
	})
	resume_edit(start_edit(api, if is_report(input) { origin } else { input }, 'similar', evidence, prompt)!, true)!
}

// Ask the agent to fix the vulnerability in a REPORT.md and commit it locally, citing the report ID.
fn cmd_fix(api Repository, path string, ctx string) ! {
	full := os.real_path(path)
	report := os.read_file(full)!
	prompt := render(prompt_fix, {
		'advisory': advisory_path(full)
		'format':   format
		'antfind':  reports_base()
		'attic':    project_setting('attic')
		'id':     report_id(full)
		'repo':   api.repo
		'cli':    api.cli()
		'path':   full
		'ctx':    ctx
		'report': report
	})
	resume_edit(start_edit(api, full, 'fix', report, prompt)!, true)!
}

fn report_id(path string) string {
	header := parse_report(os.read_file(path) or { '' })[2]
	return if header != '' { header } else { os.file_name(os.dir(path)) }
}

// The fix prompt asks for leading Verdict: and Reason: lines; tolerate Markdown around them.
fn fix_verdict(reply string) (string, string) {
	mut verdict, mut reason := '', ''
	for line in reply.split_into_lines() {
		t := line.trim_space().trim('*_`#> ')
		field := t.all_before(':').trim('*_` ').to_lower()
		value := t.all_after_first(':').trim('*_` ')
		if verdict == '' && field == 'verdict' {
			v := value.to_lower().replace('-', ' ')
			verdict = ['confirmed', 'false positive', 'already fixed', 'inconclusive'].filter(v.starts_with(it))[0] or { '' }
		} else if reason == '' && field == 'reason' {
			reason = value
		}
		if verdict != '' && reason != '' { break }
	}
	return verdict, reason
}

// Report the verdict; a false positive marks the report invalid for every gsadv process.
fn fix_outcome(session EditSession, reply string) string {
	verdict, reason := fix_verdict(reply)
	id := report_id(session.id)
	detail := if reason == '' { '' } else { ': ${reason}' }
	if verdict == '' {
		return 'The reply has no Verdict line; read the summary and press m on ${id} to mark it.'
	}
	if verdict != 'false positive' { return 'Verdict for ${id}: ${verdict}${detail}' }
	note := 'false positive' + if reason == '' { ' (see the fix summary)' } else { ': ${reason}' }
	api := repository_location(session.repo, session.provider, session.host) or {
		return 'Verdict for ${id}: false positive${detail}\nCould not mark it invalid: ${err}'
	}
	api.mark_invalid('report:' + id, note) or {
		return 'Verdict for ${id}: false positive${detail}\nCould not mark it invalid: ${err}'
	}
	return 'Verdict for ${id}: false positive${detail}\nMarked ${id} invalid; no code was changed.'
}

fn cmd_edit(api Repository, id string) ! {
	text := api.advisory(id)!
	resume_edit(start_edit(api, id, 'edit', text, '')!, false)!
}

fn (api Repository) reply_instructions() string {
	reply := render(prompt_reply, {
		'format': format
	})
	if api.provider == 'github' { return reply }
	return reply.replace('GitHub', 'GitLab').replace('github_login', 'gitlab_username') + '\n' + prompt_gitlab
}

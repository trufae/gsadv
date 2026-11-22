module main

import os
import json2

fn test_review_diff_choices() ! {
	orig := 'summary: Old\nseverity: high\n---\nBefore\n'
	proposed := 'summary: New\nseverity: high\n---\nAfter\n'
	diff := udiff('Review notes', orig, proposed)!
	assert apply(orig, diff)! == proposed
	assert apply(orig, diff.replace('+summary: New\n', ''))!.starts_with('severity: high\n')
	assert apply(orig, diff.replace('-summary: Old\n', ''))!.starts_with('summary: Old\nsummary: New\n')
	assert apply(orig, diff.replace(' severity: high', ' severity: low'))!.contains('severity: low\n')
	assert apply(orig, diff.replace('+After', '+Reworded'))!.ends_with('Reworded\n')
	// Removing both sides rejects the replacement without consuming the next line.
	assert apply(orig, diff.replace('-summary: Old\n+summary: New\n', ''))!.starts_with('summary: Old\nseverity: high\n')
}

fn test_review_diff_rejects_damage() ! {
	orig := 'summary: Old\n---\nBefore\n'
	diff := udiff('', orig, 'summary: New\n---\nAfter\n')!
	for damaged in [diff.all_before('@@'), diff + 'broken\n',
		diff.replace('-Before', '-not in original'), diff.replace('@@ -1,3', '@@ -2,3'),
		diff + ' extra context\n', diff + '@@ -1,3 +1,3 @@\n'] {
		if result := apply(orig, damaged) {
			assert false, 'accepted damaged diff: ${result}'
		}
	}
}

fn test_review_diff_empty_and_single_line() ! {
	assert udiff('No changes', 'same\n', 'same\n')! == ''
	assert apply('old\n', udiff('', 'old\n', 'new\n')!)! == 'new\n'
	assert apply('', udiff('', '', 'new\n')!)! == 'new\n'
	assert apply('old', udiff('', 'old', 'new')!)! == 'new\n'
}

fn test_saved_ai_reply() ! {
	notes, text := ai_reply('Review notes\n\nsummary: Revised\n---\nDetails\n')!
	assert notes == 'Review notes'
	assert parse(text)!.summary == 'Revised'
	bare_notes, bare_text := ai_reply('summary: Revised\n---\nDetails\n')!
	assert bare_notes == ''
	assert bare_text == text
	if _, _ := ai_reply('unfinished analysis') {
		assert false, 'accepted a reply without an advisory'
	}
}

fn test_recovery_sessions_do_not_overwrite_previous_work() ! {
	api := Repository(GitHub{ repo: 'owner/repo' })
	a := start_edit(api, 'GHSA-test', 'review', 'original', 'prompt')!
	b := start_edit(api, 'GHSA-test', 'review', 'other original', 'other prompt')!
	defer {
		os.rmdir_all(a) or {}
		os.rmdir_all(b) or {}
	}
	assert a != b
	assert os.read_file(os.join_path(a, 'original.md'))! == 'original'
	assert os.read_file(os.join_path(a, 'prompt.txt'))! == 'prompt'
	assert os.read_file(os.join_path(b, 'original.md'))! == 'other original'
}

fn test_claude_progress_keeps_text_separate_from_events() ! {
	dir := start_edit(GitHub{repo: 'owner/repo'}, 'GHSA-test', 'review', '', '')!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'reply.txt')
	os.write_file(path, '')!
	mut stream := ClaudeStream{}
	partial := '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Checking café"},{"type":"tool_use","name":"Read","input":{"file_path":"parser.c"}}]}}\n'
	for byte in partial.bytes() {
		stream.feed([byte].bytestr(), path, false)
	}
	assert stream.failure == ''
	assert os.read_file(path)! == 'Checking café\n'
	stream.feed('{"type":"assistant","parent_tool_use_id":"child","message":{"content":[{"type":"text","text":"child notes"}]}}\n', path, false)
	assert os.read_file(path)! == 'Checking café\n'
	final := 'summary: Final\n---\nVerified café\n'
	// A short-lived child may leave its last event without a trailing newline.
	stream.feed('{"type":"result","is_error":false,"result":${json2.encode(final)}}', path, true)
	assert stream.failure == ''
	assert stream.finished
	assert os.read_file(path)! == final
}

fn test_claude_completed_reply_survives_background_results() ! {
	dir := start_edit(GitHub{repo: 'owner/repo'}, 'GHSA-test', 'review', '', '')!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'reply.txt')
	os.write_file(path, 'Checking the fix\n')!
	mut stream := ClaudeStream{}
	stream.feed('{"type":"result","parent_tool_use_id":"child","is_error":false,"result":"child notes"}\n', path, false)
	assert !stream.finished
	assert os.read_file(path)! == 'Checking the fix\n'
	final := 'Review notes\nsummary: Final\nseverity: low\n---\nVerified details\n'
	stream.feed('{"type":"result","is_error":false,"result":${json2.encode(final)}}\n', path, false)
	assert stream.finished
	assert os.read_file(path)! == final
	notice := 'A background lookup hit its time limit. The advisory above stands as written.'
	stream.feed('{"type":"system","subtype":"task_notification","status":"stopped"}\n', path, false)
	stream.feed('{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":${json2.encode(notice)}}]}}\n', path, false)
	assert os.read_file(path)! == final
	for result in [notice, '', 'summary: Later\n---\nA later turn\n'] {
		stream.feed('{"type":"result","is_error":false,"result":${json2.encode(result)}}\n', path, false)
		assert os.read_file(path)! == final
	}
	stream.feed('{"type":"result","is_error":true,"errors":["background failure"]}', path, true)
	assert stream.failure == ''
	assert os.read_file(path)! == final
	notes, text := ai_reply(os.read_file(path)!)!
	assert notes == 'Review notes'
	assert parse(text)!.summary == 'Final'
}

fn test_claude_errors_retain_partial_reply() ! {
	dir := start_edit(GitHub{repo: 'owner/repo'}, 'GHSA-test', 'review', '', '')!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'reply.txt')
	os.write_file(path, 'partial review')!
	mut stream := ClaudeStream{}
	stream.feed('{"type":"result","is_error":true,"errors":["request failed"]}\n', path, true)
	assert stream.failure.contains('request failed')
	assert !stream.finished
	assert os.read_file(path)! == 'partial review'
	stream.feed('not JSON\n', path, true)
	assert stream.failure.contains('invalid Claude event')
	assert os.read_file(path)! == 'partial review'
}

fn test_claude_tool_progress_quotes_controls_and_bounds_unicode() ! {
	command := 'printf "café"\n\tprintf "\\n"\r\x1b[2J'
	block := json2.decode[ClaudeContent]('{"type":"tool_use","name":"Bash","input":{"command":${json2.encode(command)}}}')!
	progress := claude_tool_progress(block)
	assert progress.split_into_lines().len == 2
	assert !progress.contains('\x1b') && !progress.contains('\r') && !progress.contains('\t')
	assert progress.contains(json2.encode(command))
	long := json2.decode[ClaudeContent]('{"type":"tool_use","name":"Bash","input":{"command":${json2.encode('界'.repeat(1100))}}}')!
	preview := claude_tool_progress(long).all_after('  command: ')
	assert preview == '"' + '界'.repeat(996) + '...'
	// Input-less and unfamiliar tools must not break stream decoding.
	unknown := json2.decode[ClaudeContent]('{"type":"tool_use","name":"Custom"}')!
	assert claude_tool_progress(unknown) == '[claude] tool: Custom'
}

fn test_recovered_transcript_keeps_partial_text() ! {
	dir := start_edit(GitHub{repo: 'owner/repo'}, 'GHSA-test', 'review', '', '')!
	defer { os.rmdir_all(dir) or {} }
	log := os.join_path(dir, 'claude.jsonl')
	quota := "You've hit your individual spend limit"
	lines := [
		// A previous, completed run must not leak into --last output.
		'{"type":"assistant","message":{"content":[{"type":"text","text":"old answer"}]}}',
		'{"type":"system","subtype":"task_progress","summary":"ignored"}',
		// A finished run closes with an empty result, after its reply.
		'{"type":"result","is_error":false,"result":"old answer"}',
		'{"type":"result","is_error":false,"result":""}',
		// The interrupted run: findings text, a tool call, then the quota failure.
		'{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"First finding: heap overflow"},{"type":"tool_use","name":"Bash","input":{"command":"make test"}}]}}',
		'{"type":"assistant","message":{"content":[{"type":"text","text":"${quota}"}]}}',
		'{"type":"result","is_error":true,"result":"${quota}"}',
		'{"type":"result","is_error":false,"result":""}',
	]
	os.write_file(log, lines.join('\n') + '\n')!
	text := recover_chat(log, RecoverOptions{ last: true })!
	assert text.contains('First finding: heap overflow')
	assert !text.contains('old answer')
	assert !text.contains('hidden')
	assert !text.contains('make test')
	// The quota text only appears as the stop reason, never as assistant text.
	assert text.contains('Stopped:** ${quota}')
	assert text.split_into_lines().filter(it.starts_with('### ')).len == 1
	with_tools := recover_chat(log, RecoverOptions{ last: true, no_tools: false })!
	assert with_tools.contains('Bash') && with_tools.contains('make test')
	everything := recover_chat(log, RecoverOptions{})!
	assert everything.contains('old answer')
}

fn test_recovered_last_run_without_failure_is_not_a_stop() ! {
	dir := start_edit(GitHub{repo: 'owner/repo'}, 'GHSA-test', 'review', '', '')!
	defer { os.rmdir_all(dir) or {} }
	log := os.join_path(dir, 'claude.jsonl')
	lines := [
		'{"type":"assistant","message":{"content":[{"type":"text","text":"old answer"}]}}',
		'{"type":"result","is_error":false,"result":"old answer"}',
		'{"type":"result","is_error":false,"result":""}',
		'{"type":"assistant","message":{"content":[{"type":"text","text":"final answer"}]}}',
		'{"type":"result","is_error":false,"result":"final answer"}',
		'{"type":"result","is_error":false,"result":""}',
	]
	os.write_file(log, lines.join('\n') + '\n')!
	text := recover_chat(log, RecoverOptions{ last: true })!
	assert text.contains('final answer')
	assert !text.contains('old answer')
	assert !text.contains('Stopped:')
}

fn test_recovered_transcript_survives_damaged_log() ! {
	dir := start_edit(GitHub{repo: 'owner/repo'}, 'GHSA-test', 'review', '', '')!
	defer { os.rmdir_all(dir) or {} }
	log := os.join_path(dir, 'claude.jsonl')
	os.write_file(log, '{"type":"assistant","message":{"content":[{"type":"text","text":"kept"}]}}\n{"type":\n')!
	text := recover_chat(log, RecoverOptions{})!
	assert text.contains('kept')
	assert text.contains('Invalid log line')
	if _ := recover_chat(os.join_path(dir, 'missing.jsonl'), RecoverOptions{}) {
		assert false, 'accepted a missing transcript'
	}
}

fn test_cli_accepts_recovery_directory() ! {
	dir := start_edit(GitHub{repo: 'owner/repo'}, 'GHSA-test', 'review', '', '')!
	defer { os.rmdir_all(dir) or {} }
	os.write_file(os.join_path(dir, 'claude.jsonl'), '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}\n')!
	out := os.join_path(dir, 'out.md')
	cmd_recover([dir, '-o', out, '--raw'])!
	assert os.read_file(out)!.contains('partial')
	if _ := cmd_recover([]string{}) {
		assert false, 'accepted a missing log'
	}
	if _ := cmd_recover([dir, '--nope']) {
		assert false, 'accepted an unknown option'
	}
}

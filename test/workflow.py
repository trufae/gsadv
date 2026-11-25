#!/usr/bin/env python3
"""Workflow smoke checks with fake gh, AI and editor commands; no network access.

Usage: python3 test/workflow.py /path/to/gsadv
"""

import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time

from credits import Terminal


ORIGINAL = '# GHSA-test draft\nsummary: Original\nseverity: high\n---\nBefore\n'
REPLY = 'Review notes\nsummary: Revised\nseverity: high\n---\nAfter\n'
MANUAL = 'summary: Manual\nseverity: low\n---\nResolved by hand\n'
PATCH = 'diff --git a/test.c b/test.c\n--- a/test.c\n+++ b/test.c\n@@ -1 +1 @@\n-"\x1b[31m"\n+"\x1b[32m"\n'
STUB = '''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ['TEST_ROOT'])
name = Path(sys.argv[0]).name
if name == 'gh':
    args = sys.argv[1:]
    with (root / 'gh.calls').open('a') as f:
        f.write(json.dumps(args) + '\\n')
    patch_mode = os.environ.get('GH_PATCH_MODE')
    is_patch = 'Accept: application/vnd.github.patch' in args
    if patch_mode and not is_patch:
        assert '--allow-escape-sequences' not in args, args
    if patch_mode and is_patch:
        if patch_mode == 'legacy' and '--allow-escape-sequences' in args:
            print('unknown flag: --allow-escape-sequences\\n\\nUsage: gh api <endpoint> [flags]', file=sys.stderr)
            sys.exit(1)
        if patch_mode == 'fail':
            print('HTTP 404: Not Found', file=sys.stderr)
            sys.exit(1)
        if patch_mode != 'legacy' and '--allow-escape-sequences' not in args:
            print('the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway', file=sys.stderr)
            sys.exit(1)
        print((root / 'patch').read_text(), end='')
    elif '--input' in args:
        payload = Path(args[args.index('--input') + 1]).read_text()
        (root / 'payload.json').write_text(payload)
        if (root / 'fail-api').exists():
            (root / 'fail-api').unlink()
            print('HTTP 422: rejected advisory', file=sys.stderr)
            sys.exit(1)
        if not os.environ.get('GH_DROP_SAVE'):
            (root / 'saved.json').write_text(payload)
        print('GHSA-test')
    elif '--paginate' in args:
        summary = 'Test advisory'
        if (root / 'saved.json').exists():
            summary = json.loads((root / 'saved.json').read_text())['summary']
        print('GHSA-test\\tdraft\\t-\\thigh\\t' + summary + '\\t\\t')
    else:
        if (root / 'saved.json').exists():
            if (root / 'fail-reload').exists():
                (root / 'fail-reload').unlink()
                print('HTTP 503: reload unavailable', file=sys.stderr)
                sys.exit(1)
            a = json.loads((root / 'saved.json').read_text())
            lines = ['# GHSA-test draft', 'summary: ' + a['summary'],
                     'severity: ' + a.get('severity', ''),
                     'cvss: ' + a.get('cvss_vector_string', ''),
                     'cwe: ' + ', '.join(a.get('cwe_ids', [])),
                     'credits: ' + ', '.join(c['login'] + ':' + c['type']
                                             for c in a.get('credits', []))]
            for v in a.get('vulnerabilities', []):
                lines += ['package: ' + v['package']['name'],
                          'ecosystem: ' + v['package']['ecosystem'],
                          'affected: ' + v.get('vulnerable_version_range', ''),
                          'patched: ' + v.get('patched_versions', ''),
                          'functions: ' + ', '.join(v.get('vulnerable_functions', []))]
            print('\\n'.join(lines + ['---', a['description']]))
        else:
            print((root / 'original').read_text(), end='')
elif name == 'ai':
    with (root / 'ai.calls').open('a') as f:
        f.write('run\\n')
    with (root / 'ai.prompts').open('a') as f:
        f.write(json.dumps(sys.stdin.read()) + '\\n')
    print((root / 'reply').read_text(), end='', flush=True)
    if os.environ.get('AI_WAIT'):
        signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
        (root / 'ai.ready').touch()
        try:
            time.sleep(30)
        finally:
            (root / 'ai.stopped').touch()
    sys.exit(int(os.environ.get('AI_EXIT', '0')))
elif name == 'r2':
    command = sys.argv[sys.argv.index('-c') + 1]
    path = command.removeprefix('cat -m ').removesuffix('~..')
    text = Path(path).read_text()
    (root / 'viewed.md').write_text(text)
    print(text, end='')
else:
    path = Path(sys.argv[1])
    (root / 'editor-buffer').write_text(path.read_text())
    mode = os.environ.get('EDITOR_MODE', '')
    if mode == 'wait':
        subprocess.run(['stty', '-icanon', '-echo', '-opost'], check=True)
        signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
        print('Editor ready', flush=True)
        time.sleep(30)
    if mode == 'fail':
        sys.exit(2)
    if mode == 'empty':
        path.write_text('')
    if mode == 'comment':
        path.write_text('# Only a comment changed\\n' + path.read_text())
    if path.suffix == '.diff':
        if mode in ('broken', 'manual', 'retry'):
            if mode == 'retry' and (root / 'clean.diff').exists():
                path.write_text((root / 'clean.diff').read_text())
            else:
                (root / 'clean.diff').write_text(path.read_text())
                path.write_text(path.read_text() + 'broken line\\n')
        elif mode == 'invalid':
            path.write_text(path.read_text().replace('+summary: Revised', '+unknown: Revised'))
    elif mode in ('manual', 'api-edit'):
        path.write_text((root / 'manual').read_text())
'''


def saved_dir(output):
    match = re.search(r'Recovery files: (.+)', output)
    assert match, output
    return Path(match[1])


def run(binary, root, mode='', answer='', args=None, **extra):
    # Each CLI scenario starts with the original unless explicitly continuing it.
    if not extra.get('GH_PERSIST'):
        (root / 'saved.json').unlink(missing_ok=True)
    env = os.environ | {
        'PATH': str(root) + os.pathsep + os.environ['PATH'],
        'TEST_ROOT': str(root), 'TMPDIR': str(root),
        'GSADV_AI': 'ai', 'EDITOR': 'editor', 'EDITOR_MODE': mode,
    } | extra
    result = subprocess.run(
        [binary, *(args or ['-r', 'owner/repo', 'review', 'GHSA-test'])],
        env=env, input=answer, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=10,
    )
    return result, env


def setup(root):
    for name in ('gh', 'ai', 'editor', 'r2'):
        (root / name).write_text(STUB)
        (root / name).chmod(0o700)
    for name, text in [('original', ORIGINAL), ('reply', REPLY), ('manual', MANUAL)]:
        (root / name).write_text(text)


def payload(root):
    return json.loads((root / 'payload.json').read_text())


def manual_checks(binary, root):
    root.mkdir()
    setup(root)
    args = ['-r', 'owner/repo', 'new']
    # Opening, cancelling and editor failure must not run AI or fetch source data.
    for mode in ('', 'empty', 'fail'):
        result, _ = run(binary, root, mode, args=args, GSADV_AI='false')
        assert result.returncode == 0, result.stdout
        assert 'Opening edit.md in editor' in result.stdout
        assert 'No changes saved to the server' in result.stdout
        assert not (root / 'ai.calls').exists()
        assert not (root / 'gh.calls').exists()
        template = (root / 'editor-buffer').read_text()
        assert 'summary:\n' in template and 'credits:\n' in template
        assert 'package: repo\n' in template and 'affected:\n' in template
        for section in ('Impact', 'Details', 'Proof of concept', 'Patches',
                        'Workarounds', 'References', 'Acknowledgements'):
            assert f'## {section}\n' in template, template
        directory = saved_dir(result.stdout)
        assert (directory / 'original.md').read_text() == template
        if mode == 'fail':
            # Resume and paste a whole advisory over the template.
            result, _ = run(binary, root, 'manual', args=['resume', str(directory)],
                            GSADV_AI='false')
            assert result.returncode == 0, result.stdout
            assert payload(root)['summary'] == 'Manual'
            assert payload(root)['description'] == 'Resolved by hand'
            calls = [json.loads(line) for line in (root / 'gh.calls').read_text().splitlines()]
            assert len(calls) == 1 and calls[0][calls[0].index('--method') + 1] == 'POST', calls
            assert not directory.exists()
        else:
            shutil.rmtree(directory)

    # N opens the editor from every tab, including an empty selection.
    env = {'GSADV_AI': 'false', 'EDITOR': 'editor', 'EDITOR_MODE': 'empty'}
    before = (root / 'payload.json').read_text()
    (root / 'saved.json').unlink(missing_ok=True)
    with Terminal(binary, root, 'tui', env, controlling=True) as ui:
        ui.expect('Test advisory')
        ui.send('/')
        ui.expect('Filter text:')
        ui.send('nothing-matches-this\n')
        ui.expect('No matches.')
        for next_view in ('commits', 'issues', 'PRs', 'advisories'):
            ui.send('N')
            screen = ui.expect('Press Enter to return')
            assert 'Opening edit.md in editor' in screen, screen
            assert 'commit or issue/PR URL' not in screen, screen
            assert 'summary:\n' in (root / 'editor-buffer').read_text()
            shutil.rmtree(saved_dir(screen.replace('\r', '')))
            ui.send('\n')
            ui.expect('N manual draft')
            ui.send('\t')
            ui.expect('[' + next_view + ' ')
        ui.send('q')
        ui.finish()
    assert not (root / 'ai.calls').exists()
    assert (root / 'payload.json').read_text() == before


def github_patch_checks(binary, root):
    root.mkdir()
    setup(root)
    (root / 'patch').write_text(PATCH)
    for mode in ('current', 'legacy'):
        for source in ('abcdef1234', 'https://github.com/owner/repo/pull/42'):
            (root / 'gh.calls').write_text('')
            result, _ = run(binary, root, mode='empty', GH_PATCH_MODE=mode,
                            args=['-r', 'owner/repo', 'new', source])
            assert result.returncode == 0, result.stdout
            prompt = json.loads((root / 'ai.prompts').read_text().splitlines()[-1])
            assert PATCH in prompt, repr(prompt)
            assert (saved_dir(result.stdout) / 'prompt.txt').read_text() == prompt
            calls = [json.loads(line) for line in (root / 'gh.calls').read_text().splitlines()]
            patches = [args for args in calls if 'Accept: application/vnd.github.patch' in args]
            assert len(patches) == (2 if mode == 'legacy' else 1), patches
            assert '--allow-escape-sequences' in patches[0], patches
            if mode == 'legacy':
                assert '--allow-escape-sequences' not in patches[1], patches
            assert not any('--input' in args for args in calls), calls

    # Other API errors must propagate without retrying or starting the AI.
    (root / 'gh.calls').write_text('')
    ai_calls = (root / 'ai.calls').read_text()
    result, _ = run(binary, root, GH_PATCH_MODE='fail',
                    args=['-r', 'owner/repo', 'new', 'abcdef1234'])
    assert result.returncode != 0 and 'HTTP 404: Not Found' in result.stdout, result.stdout
    assert len((root / 'gh.calls').read_text().splitlines()) == 1
    assert (root / 'ai.calls').read_text() == ai_calls

    # Exercise the reported n-key path through the CLI child in a real PTY.
    env = {'GSADV_AI': 'ai', 'EDITOR': 'editor', 'EDITOR_MODE': 'empty',
           'GH_PATCH_MODE': 'current'}
    with Terminal(binary, root, 'tui', env, controlling=True) as ui:
        ui.expect('Test advisory')
        ui.expect('a actions')
        ui.send('n')
        ui.expect('commit or issue/PR URL')
        ui.send('abcdef1234\n')
        screen = ui.expect('Press Enter to return')
        assert 'Workflow exited' not in screen, screen
        assert PATCH in json.loads((root / 'ai.prompts').read_text().splitlines()[-1])
        ui.send('\n')
        ui.expect('a actions')
        ui.send('q')
        ui.finish()


def tui_checks(binary, root):
    env = {'GSADV_AI': 'ai', 'EDITOR': 'editor', 'EDITOR_MODE': ''}
    (root / 'saved.json').unlink(missing_ok=True)
    # Accepting the unchanged review diff must PATCH the AI version, report success,
    # and reload the updated advisory before displaying the list again.
    with Terminal(binary, root, 'tui', env | {'GH_PERSIST': '1'}, controlling=True) as ui:
        ui.expect('Test advisory')
        ui.send('r')
        ui.expect('extra context (optional):')
        ui.send('\n')
        screen = ui.expect('Press Enter to return')
        assert 'Opening review.diff in editor' in screen
        assert 'Saved changes to GHSA-test on github.' in screen
        assert payload(root)['summary'] == 'Revised'
        assert payload(root)['description'] == 'After'
        assert '+summary: Revised' in (root / 'editor-buffer').read_text()
        assert not saved_dir(screen.replace('\r', '')).exists()
        # Reopen the server version and request another review from that view.
        ui.send('v\n')
        ui.expect('summary: Revised')
        screen = ui.expect('Press Enter to return')
        assert 'summary: Revised' in screen and 'After' in screen, screen
        assert 'summary: Revised' in (root / 'viewed.md').read_text()
        (root / 'reply').write_text(REPLY.replace('Revised', 'Second review').replace('After', 'Final text'))
        ui.send('r\n')
        ui.expect('extra context (optional):')
        ui.send('Check the revised wording\n')
        screen = ui.expect('Press Enter to return')
        assert 'Saved changes to GHSA-test on github.' in screen
        prompt = json.loads((root / 'ai.prompts').read_text().splitlines()[-1])
        assert 'summary: Revised' in prompt and 'After' in prompt
        assert 'Extra context: Check the revised wording' in prompt
        assert payload(root)['description'] == 'Final text'
        ui.send('\n')
        ui.expect('Second review')
        ui.send('\n')
        ui.expect('summary: Second review')
        screen = ui.expect('Press Enter to return')
        assert 'summary: Second review' in screen and 'Final text' in screen, screen
        ui.send('\x1b')
        ui.expect('a actions')
        ui.send('q')
        ui.finish()

    (root / 'saved.json').unlink(missing_ok=True)
    (root / 'reply').write_text(REPLY)
    before = (root / 'payload.json').read_text()
    writes = [line for line in (root / 'gh.calls').read_text().splitlines()
              if '--input' in json.loads(line)]
    ai_calls = (root / 'ai.calls').read_text()
    sessions = set(root.glob('gsadv-*'))
    with Terminal(binary, root, 'tui', env) as ui:
        ui.expect('GHSA-test')
        ui.expect('a actions')
        for cancel in ('\x03', '\x1b', '\x04'):
            ui.send('r')
            screen = ui.expect('extra context (optional):')
            assert 'Example: Check the affected versions' in screen
            assert 'Ctrl+C or Esc to cancel' in screen
            ui.send('unfinished context' + cancel)
            ui.expect('a actions')
        ui.send('n')
        ui.expect('commit or issue/PR URL')
        ui.send('\x03')
        ui.expect('a actions')
        ui.send('\x03')
        ui.finish()
    assert (root / 'ai.calls').read_text() == ai_calls
    assert set(root.glob('gsadv-*')) == sessions

    # A failed AI reply must be visible before returning, with no editor or PATCH.
    (root / 'reply').write_text('Execution error')
    (root / 'editor-buffer').unlink()
    with Terminal(binary, root, 'tui', env, controlling=True) as ui:
        ui.expect('GHSA-test')
        ui.expect('a actions')
        ui.send('r')
        ui.expect('extra context (optional):')
        ui.send('\n')
        screen = ui.expect('Press Enter to return')
        assert 'Execution error' in screen
        assert 'No changes saved to the server.' in screen
        assert 'Saved changes to' not in screen
        assert not (root / 'editor-buffer').exists()
        ui.send('\n')
        ui.expect('a actions')
        ui.send('q')
        ui.finish()

    # Typed Ctrl+C during the AI returns to the list and preserves partial output.
    (root / 'reply').write_text('partial TUI analysis\n')
    (root / 'ai.ready').unlink(missing_ok=True)
    (root / 'ai.stopped').unlink(missing_ok=True)
    with Terminal(binary, root, 'tui', env | {'AI_WAIT': '1'}, controlling=True) as ui:
        ui.expect('GHSA-test')
        ui.expect('a actions')
        ui.send('r')
        ui.expect('extra context (optional):')
        context = 'Check affected versions and whether the fix addresses the root cause; $(touch should-not-exist)'
        ui.send(context + '\n')
        screen = ui.expect('running ai ...')
        directory = saved_dir(screen.replace('\r', ''))
        deadline = time.monotonic() + 5
        while not (root / 'ai.ready').exists():
            assert time.monotonic() < deadline
            time.sleep(0.02)
        ui.send('\x03')
        ui.expect('cancelled; recovery files')
        ui.expect('a actions')
        assert (directory / 'reply.txt').read_text() == 'partial TUI analysis\n'
        assert 'Extra context: ' + context in (directory / 'prompt.txt').read_text()
        assert not (root / 'should-not-exist').exists()
        while not (root / 'ai.stopped').exists():
            assert time.monotonic() < deadline
            time.sleep(0.02)
        ui.send('q')
        ui.finish()

    # Interrupting an editor that changed terminal modes also returns safely.
    with Terminal(binary, root, 'tui', env | {'EDITOR_MODE': 'wait'}, controlling=True) as ui:
        ui.expect('GHSA-test')
        ui.expect('a actions')
        ui.send('e')
        screen = ui.expect('Editor ready')
        directory = saved_dir(screen.replace('\r', ''))
        ui.send('\x03')
        ui.expect('cancelled; recovery files')
        ui.expect('a actions')
        assert (directory / 'edit.md').read_text() == ORIGINAL
        assert termios.tcgetattr(ui.slave)[1] == ui.attributes[1], 'editor output mode not restored'
        ui.send('q')
        ui.finish()

    # The recovery-choice prompt belongs to the child workflow too.
    (root / 'reply').write_text(REPLY)
    with Terminal(binary, root, 'tui', env | {'EDITOR_MODE': 'broken'}, controlling=True) as ui:
        ui.expect('GHSA-test')
        ui.expect('a actions')
        ui.send('r')
        ui.expect('extra context (optional):')
        ui.send('\n')
        screen = ui.expect('[q]uit and keep files [q]:')
        directory = saved_dir(screen.replace('\r', ''))
        ui.send('\x03')
        ui.expect('cancelled; recovery files')
        ui.expect('a actions')
        assert (directory / 'review.diff').read_text().endswith('broken line\n')
        ui.send('q')
        ui.finish()
    assert (root / 'payload.json').read_text() == before
    assert [line for line in (root / 'gh.calls').read_text().splitlines()
            if '--input' in json.loads(line)] == writes


def checks(binary, root):
    setup(root)
    result, _ = run(binary, root)
    assert result.returncode == 0, result.stdout
    assert payload(root)['summary'] == 'Revised'
    assert payload(root)['description'] == 'After'
    assert 'Saved changes to GHSA-test on github.' in result.stdout
    assert not saved_dir(result.stdout).exists()

    # Reader-facing findings and recovered credits must survive both save paths.
    description = '''## Details
An unchecked length in parse_record permits an out-of-bounds read of crafted input.

## Related findings
[OSS-SCAN-123](https://github.com/owner/repo/issues/123) is a variant in another reader;
its affected versions are not established by this fix.

## Verification limits
The patch was inspected; the reproducer was not run and the first fixed release is unknown.

## Acknowledgements
Alice reported the issue; scan-coverity CID 456 is recorded in the source report.

## References
https://github.com/owner/repo/commit/abcdef1234'''
    notes = 'Filled missing credits and added related finding references.'
    (root / 'reply').write_text(notes + '\nsummary: Revised\nseverity: high\n'
                              'credits: alice:reporter\n---\n' + description + '\n')
    for command, selection in [('new', 'abcdef1234'), ('review', 'GHSA-test')]:
        result, _ = run(binary, root, args=['-r', 'owner/repo', command, selection])
        assert result.returncode == 0, result.stdout
        assert payload(root)['description'] == description
        assert payload(root)['credits'] == [{'login': 'alice', 'type': 'reporter'}]
        assert notes in (root / 'editor-buffer').read_text()
        assert not saved_dir(result.stdout).exists()
    (root / 'reply').write_text(REPLY)

    # A successful gh exit with unchanged server content must not claim a save.
    result, _ = run(binary, root, GH_DROP_SAVE='1')
    assert result.returncode != 0, result.stdout
    assert 'reloaded advisory differs in: summary, description' in result.stdout
    assert 'Saved changes to' not in result.stdout
    directory = saved_dir(result.stdout)
    assert (directory / 'result.md').read_text().endswith('After\n')
    assert (directory / 'review.diff').exists()
    result, _ = run(binary, root, args=['resume', str(directory)])
    assert result.returncode == 0, result.stdout
    assert not directory.exists()

    # A PATCH followed by a read failure is unverified; preserve the recovery files.
    (root / 'fail-reload').touch()
    result, _ = run(binary, root)
    assert result.returncode != 0, result.stdout
    assert 'reloading GHSA-test failed: HTTP 503' in result.stdout
    assert 'Saved changes to' not in result.stdout
    assert (saved_dir(result.stdout) / 'result.md').exists()

    # Textual changes to comments alone do not change any submitted advisory fields.
    result, _ = run(binary, root, 'comment', args=['-r', 'owner/repo', 'edit', 'GHSA-test'])
    assert result.returncode == 0, result.stdout
    assert 'No advisory fields changed; the server was not updated.' in result.stdout
    assert 'Saved changes to' not in result.stdout

    # An unchanged advisory should show the AI notes and explain the lack of a PATCH.
    before = (root / 'payload.json').read_text()
    (root / 'reply').write_text('Verified: no changes needed\n' + ORIGINAL.split('\n', 1)[1])
    (root / 'editor-buffer').unlink()
    result, _ = run(binary, root)
    assert result.returncode == 0, result.stdout
    assert 'Verified: no changes needed' in result.stdout
    assert 'No review changes to apply; the server was not updated.' in result.stdout
    assert not (root / 'editor-buffer').exists()
    assert (root / 'payload.json').read_text() == before
    assert saved_dir(result.stdout).exists()
    (root / 'reply').write_text(REPLY)

    for mode, choice, expected in [('broken', 'n', 'Revised'),
                                   ('invalid', 'n', 'Revised'),
                                   ('manual', 'm', 'Manual'),
                                   ('retry', 'd', 'Revised')]:
        (root / 'clean.diff').unlink(missing_ok=True)
        result, _ = run(binary, root, mode, choice + '\n')
        assert result.returncode == 0, result.stdout
        assert payload(root)['summary'] == expected, result.stdout
        assert not saved_dir(result.stdout).exists()

    result, _ = run(binary, root, 'broken', 'q\n')
    directory = saved_dir(result.stdout)
    assert 'Cannot apply review diff: line ' in result.stdout
    assert (directory / 'reply.txt').read_text() == REPLY
    assert (directory / 'original.md').read_text() == ORIGINAL
    assert (directory / 'review.diff').read_text().endswith('broken line\n')
    assert directory.stat().st_mode & 0o777 == 0o700
    ai_calls = (root / 'ai.calls').read_text()
    result, _ = run(binary, root, answer='n\n', args=['resume', str(directory)])
    assert result.returncode == 0, result.stdout
    assert (root / 'ai.calls').read_text() == ai_calls
    assert not directory.exists()

    (root / 'fail-api').touch()
    result, _ = run(binary, root, answer='q\n')
    assert result.returncode != 0, result.stdout
    directory = saved_dir(result.stdout)
    assert 'HTTP 422' in result.stdout
    assert (directory / 'result.md').read_text().endswith('After\n')
    (directory / 'user-notes').write_text('keep this')
    result, _ = run(binary, root, args=['resume', str(directory)])
    assert result.returncode == 0, result.stdout
    assert (directory / 'user-notes').read_text() == 'keep this'
    assert not (directory / 'reply.txt').exists()

    (root / 'fail-api').touch()
    result, _ = run(binary, root, 'api-edit', 'e\n')
    assert result.returncode == 0, result.stdout
    assert payload(root)['summary'] == 'Manual'

    for mode in ('empty', 'fail'):
        before = (root / 'payload.json').read_text()
        result, _ = run(binary, root, mode)
        assert saved_dir(result.stdout).exists()
        assert (root / 'payload.json').read_text() == before
        assert 'No changes saved to the server' in result.stdout
        assert 'Saved changes to' not in result.stdout

    # Ordinary edit/new share the recovery path and must retain their save behavior.
    before = (root / 'payload.json').read_text()
    result, _ = run(binary, root, args=['-r', 'owner/repo', 'edit', 'GHSA-test'])
    assert saved_dir(result.stdout).exists()
    assert (root / 'payload.json').read_text() == before
    result, _ = run(binary, root, 'manual', args=['-r', 'owner/repo', 'edit', 'GHSA-test'])
    assert result.returncode == 0, result.stdout
    assert payload(root)['summary'] == 'Manual'
    result, _ = run(binary, root, args=['-r', 'owner/repo', 'new', 'abcdef1234'])
    assert result.returncode == 0, result.stdout
    assert payload(root)['summary'] == 'Revised'
    assert not saved_dir(result.stdout).exists()

    # EOF at either recovery prompt aborts without spinning or submitting changes.
    before = (root / 'payload.json').read_text()
    result, _ = run(binary, root, 'broken')
    assert saved_dir(result.stdout).exists()
    result, _ = run(binary, root, 'invalid', 'm\n')
    assert 'Edit again? [Y/n]' in result.stdout
    assert saved_dir(result.stdout).exists()
    assert (root / 'payload.json').read_text() == before

    # A nonzero AI exit must keep even a complete reply for a later resume.
    result, _ = run(binary, root, AI_EXIT='1')
    assert result.returncode != 0
    assert 'No changes saved to the server.' in result.stdout
    assert REPLY in result.stdout
    assert 'Saved changes to' not in result.stdout
    directory = saved_dir(result.stdout)
    assert (directory / 'reply.txt').read_text() == REPLY
    assert result.stdout.rstrip().endswith(f"Resume without AI: gsadv resume '{directory}'")
    result, env = run(binary, root, args=['resume', str(directory)])
    assert result.returncode == 0, result.stdout

    # Older Claude logs can contain a completed advisory after a waiting result.
    for missing in (False, True):
        (root / 'reply').write_text('Waiting for the background build.\n')
        result, _ = run(binary, root, AI_EXIT='1')
        assert result.returncode != 0, result.stdout
        directory = saved_dir(result.stdout)
        if missing:
            (directory / 'reply.txt').unlink()
        events = [dict(type='result', is_error=False, result='Waiting for the background build.'),
                  dict(type='result', is_error=False, result=REPLY),
                  dict(type='result', is_error=False, result='A later background notice.')]
        (directory / 'claude.jsonl').write_text('\n'.join(map(json.dumps, events)) + '\n')
        ai_calls = (root / 'ai.calls').read_text()
        result, _ = run(binary, root, args=['resume', str(directory)], GSADV_AI='false')
        assert result.returncode == 0, result.stdout
        assert 'Recovered completed advisory from' in result.stdout
        assert payload(root)['summary'] == 'Revised'
        assert (root / 'ai.calls').read_text() == ai_calls
        assert not directory.exists()

    # Ctrl+C while generating leaves partial output and gives a clean exit status.
    (root / 'reply').write_text('partial expensive analysis\n')
    with (root / 'interrupt.log').open('w+') as output:
        process = subprocess.Popen(
            [binary, '-r', 'owner/repo', 'review', 'GHSA-test'],
            env=env | {'AI_WAIT': '1'}, stdin=subprocess.PIPE,
            stdout=output, stderr=subprocess.STDOUT, start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 10
            while not (root / 'ai.ready').exists():
                assert process.poll() is None
                assert time.monotonic() < deadline
                time.sleep(0.02)
            os.killpg(process.pid, signal.SIGINT)
            assert process.wait(timeout=5) == 130
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        output.seek(0)
        log = output.read()
        assert 'Interrupted. Saved work' in log, log
        directory = saved_dir(log)
        assert (directory / 'reply.txt').read_text() == 'partial expensive analysis\n'
        result, _ = run(binary, root, args=['resume', str(directory)])
        assert result.returncode != 0
        assert 'no advisory in saved reply.txt' in result.stdout
        assert (directory / 'reply.txt').exists()

    # Ctrl+C at the recovery prompt must also leave the edited diff intact.
    (root / 'reply').write_text(REPLY)
    with (root / 'prompt-interrupt.log').open('w+') as output:
        process = subprocess.Popen(
            [binary, '-r', 'owner/repo', 'review', 'GHSA-test'],
            env=env | {'EDITOR_MODE': 'broken'}, stdin=subprocess.PIPE,
            stdout=output, stderr=subprocess.STDOUT, start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 10
            while True:
                output.seek(0)
                if '[q]uit and keep files [q]:' in output.read():
                    break
                assert process.poll() is None
                assert time.monotonic() < deadline
                time.sleep(0.02)
            os.killpg(process.pid, signal.SIGINT)
            assert process.wait(timeout=5) == 130
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        output.seek(0)
        log = output.read()
        assert 'Interrupted. Saved work' in log, log
        directory = saved_dir(log)
        assert (directory / 'reply.txt').read_text() == REPLY
        assert (directory / 'review.diff').read_text().endswith('broken line\n')


if __name__ == '__main__':
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='gsadv-workflow-test-') as tmp:
        checks(binary, Path(tmp))
        tui_checks(binary, Path(tmp))
        github_patch_checks(binary, Path(tmp) / 'patches')
        manual_checks(binary, Path(tmp) / 'manual')
    print('Workflow recovery checks passed')

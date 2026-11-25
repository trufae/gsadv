#!/usr/bin/env python3
"""Offline integration checks: python3 test/gitlab_smoke.py /path/to/gsadv."""
import json
from contextlib import ExitStack
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import parse_qs, urlsplit


def stub():
    args = sys.argv[1:]
    client = Path(sys.argv[0]).name
    root = Path(os.environ['FORGE_FIXTURE'])
    if client == 'r2':
        return
    if client == 'agent':
        prompt = sys.stdin.read()
        (root / 'prompt').write_text(prompt)
        if prompt.startswith('Review this commit, issue or pull/merge request'):
            print('## Review\nCheck the parser bounds before reading.\nVerified the supplied diff.')
            sys.exit(1 if os.environ.get('FAIL_AI') else 0)
        print('summary: Reviewed report\nseverity: high\ncwe: CWE-125\ncredits: alice:finder\n'
              'package: parser\necosystem: other\naffected: < 2\npatched: 2\n---\n'
              'Verified bounds check. CVE-2026-12345\n'
              'https://gitlab.com/group/sub/repo/-/merge_requests/42')
        sys.exit(1 if os.environ.get('FAIL_AI') else 0)
    assert args[0] == 'api', args
    host = args[args.index('--hostname') + 1]
    method = args[args.index('--method') + 1] if '--method' in args else 'GET'
    path = next(a for a in args if a.startswith(('projects/', 'repos/')))
    payload = json.loads(Path(args[args.index('--input') + 1]).read_text()) if '--input' in args else {}
    with (root / 'calls').open('a') as f:
        f.write(json.dumps(dict(client=client, host=host, method=method, path=path, payload=payload, args=args)) + '\n')
    if os.environ.get('FAIL_API'):
        sys.exit('403 Forbidden: fixture denied access')
    if client == 'gh':
        assert host in ['github.com', 'code.example']
        if path.split('?')[0] == 'repos/owner/repo/issues/42/comments':
            if method == 'POST':
                assert set(payload) == {'body'} and payload['body'].strip()
                print(f'https://{host}/owner/repo/pull/42#issuecomment-99')
            else:
                print('### @alice\nDiscussion evidence')
            return
        if path.startswith('repos/owner/repo/issues?'):
            if 'labels=' not in path:
                print(f'https://{host}/owner/repo/pull/42\t42\tPR\topen\tUnlabelled pull request')
            return
        if path == 'repos/owner/repo/pulls/42':
            print('diff --git a/parser.c b/parser.c\n-old\n+fixed' if '-H' in args
                  else '# Unlabelled pull request\nState: open\nReport body')
            return
        if '/releases?' in path:
            assert '--paginate' in args and 'per_page=100' in path
            if os.environ.get('FAIL_RELEASES') == 'silent':
                sys.exit(1)
            if os.environ.get('FAIL_RELEASES'):
                sys.exit('403 Forbidden: cannot read releases')
            print('v1.2.0\treleased\n2.0\tdraft\n3.0-rc1\tprerelease')
            return
        assert path.startswith('repos/owner/repo/security-advisories')
        if '?' in path:
            suffix = '\t\t' + os.environ.get('PATCHED', '') + '\tparser: < 1.2.0'
            assert '.patched_versions' in args[-1] and '.vulnerable_version_range' in args[-1]
            print('GHSA-abcd-efgh-ijkl\tdraft\t-\thigh\tGitHub report\t\t' + suffix)
        elif method == 'POST':
            print('{}')
        elif '.cve_id' in args[-1]:
            print('')
        else:
            print('advisory: GHSA-abcd-efgh-ijkl\nstate: draft\ncve: unassigned\nurl: https://github.com/owner/repo')
        return
    assert client == 'glab'
    assert path.startswith('projects/group%2Fsub%2Frepo/'), path
    state_path = root / 'issues.json'
    issues = json.loads(state_path.read_text())
    endpoint = urlsplit(path).path.split('/', 2)[2]
    query = parse_qs(urlsplit(path).query)
    if method == 'POST' and endpoint.endswith('/notes'):
        assert set(payload) == {'body'} and payload['body'].strip()
        result = dict(id=99, body=payload['body'])
    elif method == 'POST':
        assert endpoint == 'issues' and payload['confidential'] is True
        iid = str(max(map(int, issues)) + 1)
        issues[iid] = dict(iid=int(iid), title=payload['title'], description=payload['description'],
                           confidential=True, state='opened', labels=payload['labels'].split(','),
                           web_url=f'https://{host}/group/sub/repo/-/issues/{iid}')
        result = issues[iid]
    elif method == 'PUT':
        assert endpoint.startswith('issues/')
        result = issues[endpoint.split('/')[1]]
        if 'state_event' in payload:
            assert set(payload) == {'state_event'}
            result['state'] = 'closed' if payload['state_event'] == 'close' else 'opened'
        else:
            assert set(payload) == {'title', 'description'}
            result.update(payload)
    elif endpoint == 'releases':
        if os.environ.get('FAIL_RELEASES'):
            sys.exit('403 Forbidden: cannot read releases')
        result = [dict(tag_name='v2', released_at='2020-01-01T00:00:00Z'),
                  dict(tag_name='3', released_at='2999-01-01T00:00:00Z', upcoming_release=True)]
    elif endpoint == 'issues':
        result = [i for i in issues.values() if ('labels' not in query or query['labels'][0] in i['labels'])
                  and (query['state'][0] == 'all' or query['state'][0] == i['state'])]
    elif endpoint == 'merge_requests' or endpoint == 'merge_requests/42':
        mr = dict(iid=42, title='Fix parser', description='Merge request report', state='merged',
                  web_url=f'https://{host}/group/sub/repo/-/merge_requests/42',
                  author={'username': 'alice'}, merge_commit_sha='a'*40,
                  source_branch='fix', target_branch='main')
        if endpoint == 'merge_requests':
            result = [mr] if 'labels' not in query or query['labels'][0] == 'cve' else []
        else:
            result = mr
    elif endpoint.endswith('/notes'):
        result = [dict(id=1, body='Reproduction evidence', author={'username': 'alice'}),
                  dict(id=2, body='Follow-up evidence', author={'username': 'bob'})]
    elif endpoint.endswith(('/diffs', '/diff')):
        result = [dict(old_path='parser.c', new_path='parser.c', diff='@@ -1 +1 @@\n-old\n+fixed'),
                  dict(old_path='large.c', new_path='large.c', diff='', too_large=True)]
    elif endpoint.startswith('repository/commits/'):
        result = dict(id='a'*40, message='Fix parser', author_name='Alice', web_url='https://gitlab.com/commit')
    elif endpoint.startswith('issues/'):
        result = issues[endpoint.split('/')[1]]
    else:
        raise AssertionError((method, endpoint))
    if method != 'GET':
        state_path.write_text(json.dumps(issues))
    if isinstance(result, list):
        assert '--paginate' in args or ('page' in query and endpoint in ['issues', 'merge_requests'])
        assert args[args.index('--output') + 1] == 'ndjson'
        for item in result:
            print(json.dumps(item))
    else:
        print(json.dumps(result))


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='gsadv-gitlab-smoke-') as directory, ExitStack() as cleanup:
        root = Path(directory)
        version = (Path(__file__).resolve().parents[1] / 'VERSION').read_text().strip()
        for option in ['--version', '-v', 'version']:
            # No Git checkout or provider CLI; invalid settings must not be consulted.
            result = subprocess.run([binary, option], cwd=root,
                                    env=dict(os.environ, PATH=str(root), GSADV_PROVIDER='invalid'),
                                    capture_output=True, text=True, timeout=5)
            assert result.returncode == 0 and result.stdout == f'gsadv {version}\n', result
            assert result.stderr == '', result.stderr
        bindir = root / 'bin'
        bindir.mkdir()
        for name in ['glab', 'gh', 'agent', 'r2']:
            script = bindir / name
            script.write_text(f'#!{sys.executable}\n' + Path(__file__).read_text().split('\n', 1)[1])
            script.chmod(0o755)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('GSADV_', 'GHADV_')) and k not in ['GH_HOST', 'GITLAB_HOST']}
        env.update(PATH=str(bindir) + os.pathsep + env['PATH'], FORGE_FIXTURE=str(root),
                   XDG_STATE_HOME=str(root / 'state'), TMPDIR=str(root), EDITOR='true',
                   GSADV_AI=shlex.quote(str(bindir / 'agent')))
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        subprocess.run(['git', '-C', str(root), 'remote', 'add', 'origin', 'git@gitlab.com:group/sub/repo.git'], check=True)
        (root / 'issues.json').write_text(json.dumps({'42': dict(iid=42, title='Original report',
            description='Original details. CVE-2026-12345', confidential=True, state='opened',
            labels=['security-advisory', 'cve'], web_url='https://gitlab.com/group/sub/repo/-/issues/42')}))

        def run(*args, expected=0, stdin='', overrides=None):
            p = subprocess.run([binary, *args], cwd=root, env=dict(env, **(overrides or {})),
                               input=stdin, text=True, capture_output=True, timeout=30)
            assert (p.returncode == 0) == (expected == 0), (args, p.stdout, p.stderr)
            output = p.stdout + p.stderr
            for path in re.findall(r'^Recovery files: (.+)$', output, re.M):
                cleanup.callback(shutil.rmtree, path, ignore_errors=True)
            return output

        def calls():
            return [json.loads(line) for line in (root / 'calls').read_text().splitlines()]

        listing = run('ls')
        assert 'GL-42' in listing and '[confidential]' in listing and 'CVE-2026-12345' in listing
        assert 'Usage: gsadv ' in run('--help')
        legacy = {'GHADV_PROVIDER': 'github', 'GHADV_REPO': 'https://github.com/owner/repo'}
        assert 'GitHub report' in run('ls', overrides=legacy)
        current = dict(legacy, GSADV_PROVIDER='gitlab', GSADV_REPO='https://gitlab.com/group/sub/repo')
        assert 'GL-42' in run('ls', overrides=current)
        assert 'GL-42' in run('ls', overrides=dict(legacy, GSADV_PROVIDER='', GSADV_REPO=''))
        assert 'GL-42' in run('--provider', 'gitlab', '-r', 'https://gitlab.com/group/sub/repo', 'ls', overrides=legacy)
        assert 'MR' in run('issues') and 'merged' in run('issues')
        for overrides in [{'GSADV_LABEL': ''}, {'GHADV_LABEL': ''}]:
            assert 'MR' in run('issues', overrides=overrides)
            assert all('labels=' not in c['path'] for c in calls()[-2:])
        run('--label', '', 'issues', overrides={'GSADV_LABEL': 'missing'})
        assert all('labels=' not in c['path'] for c in calls()[-2:])
        run('issues', '', overrides={'GSADV_LABEL': 'cve'})
        assert all('labels=' not in c['path'] for c in calls()[-2:])
        subprocess.run(['git', '-C', str(root), 'config', '--local', 'gsadv.label', 'custom label'], check=True)
        run('issues')
        assert all('labels=custom+label' in c['path'] for c in calls()[-2:])
        run('issues', overrides={'GHADV_LABEL': 'cve'})
        assert all('labels=cve' in c['path'] for c in calls()[-2:])
        run('--label', 'other', 'issues', overrides={'GSADV_LABEL': 'cve'})
        assert all('labels=other' in c['path'] for c in calls()[-2:])
        subprocess.run(['git', '-C', str(root), 'config', '--unset', 'gsadv.label'], check=True)
        for subject in ['Ordinary work', 'Fix parser', 'Tagged fix ##security']:
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture',
                            '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty',
                            '-qm', subject], check=True)
        output = run('log')
        assert 'Tagged fix' in output and 'Ordinary work' not in output and 'Fix parser' not in output
        subprocess.run(['git', '-C', str(root), 'config', '--local', 'gsadv.grep', '^Fix'], check=True)
        output = run('log')
        assert 'Fix parser' in output and 'Ordinary work' not in output and 'Tagged fix' not in output
        output = run('--grep', '', 'log')
        assert all(subject in output for subject in ['Ordinary work', 'Fix parser', 'Tagged fix'])
        output = run('log', overrides={'GSADV_GREP': '', 'GHADV_GREP': '^Fix'})
        assert 'Ordinary work' in output
        subprocess.run(['git', '-C', str(root), 'config', '--unset', 'gsadv.grep'], check=True)
        run('-r', 'https://github.com/owner/repo', '--label', '', 'issues')
        assert 'labels=' not in calls()[-1]['path']
        assert calls()[-1]['client'] == 'gh'
        for url, client in [('https://github.com/owner/repo/pull/42', 'gh'),
                            ('https://gitlab.com/group/sub/repo/-/merge_requests/42', 'glab')]:
            count = len(calls())
            output = run('comment', url, 'Manual review with "quotes"\nand another line.', stdin='n\n')
            assert len(calls()) == count
            recovery = re.search(r'Recovery files: (.+)', output).group(1)
            assert 'Comment posted:' in run('resume', recovery, stdin='y\n', overrides={'GSADV_AI': 'false'})
            assert calls()[-1]['client'] == client and calls()[-1]['method'] == 'POST'
            assert calls()[-1]['payload'] == {'body': 'Manual review with "quotes"\nand another line.'}
            count = len(calls())
            assert 'already posted' in run('resume', recovery, overrides={'EDITOR': 'false'})
            assert len(calls()) == count
            output = run('review', url, 'Check bounds and tests', stdin='n\n')
            assert 'Comment saved' in output
            assert 'Extra context: Check bounds and tests' in (root / 'prompt').read_text()
            assert '+fixed' in (root / 'prompt').read_text()
            assert all(c['method'] == 'GET' for c in calls()[count:])
            assert all('security-advisories' not in c['path'] for c in calls()[count:])
            recovery = re.search(r'Recovery files: (.+)', output).group(1)
            run('resume', recovery, stdin='y\n', overrides={'GSADV_AI': 'false'})
            assert calls()[-1]['payload']['body'].startswith('## Review')
        count = len(calls())
        run('review', 'https://gitlab.com/group/sub/repo/-/merge_requests/42', expected=1, overrides={'FAIL_AI': '1'})
        assert all(c['method'] == 'GET' for c in calls()[count:])
        run('comment', 'https://github.com/owner/repo/pull/42', 'Never posted', expected=1, overrides={'EDITOR': 'false'})
        assert all(c['method'] == 'GET' for c in calls()[count:])
        run('comment', 'https://github.com/owner/repo/pull/42', stdin='y\n')
        assert all(c['method'] == 'GET' for c in calls()[count:])
        assert 'Review report saved' in run('review', 'a'*40)
        assert all(c['method'] == 'GET' for c in calls()[count:])
        assert 'visibility: confidential' in run('status', 'GL-42')
        count = len(calls())
        run('invalid', 'GL-42', 'No released version affected')
        assert 'No released version' in run('invalid', 'https://gitlab.com/group/sub/repo/-/issues/42')
        assert len(calls()) == count

        def marked_listing():
            output = run('ls')
            assert '[invalid]' not in output
            return next(line for line in output.splitlines() if 'GL-42' in line)

        marked = marked_listing()
        assert marked.startswith('! '), marked
        run('unmark', 'https://gitlab.com/group/sub/repo/-/issues/42')
        unmarked = marked_listing()
        assert unmarked.startswith('  '), unmarked
        assert marked[2:] == unmarked[2:]
        count = len(calls())
        run('publish', 'GL-42', expected=1)
        run('draft', 'GL-42', expected=1)
        run('ls', 'draft', expected=1)
        run('close', 'GL-42', stdin='n\n')
        assert len(calls()) == count
        assert 'No CVE request was submitted' in run('cve', 'GL-42')
        assert calls()[-1]['method'] == 'GET'
        run('close', 'GL-42', stdin='y\n')
        assert 'closed' in run('ls', 'closed')
        run('reopen', 'GL-42', stdin='y\n')
        assert json.loads((root / 'issues.json').read_text())['42']['confidential'] is True
        output = run('new', 'https://gitlab.com/group/sub/repo/-/merge_requests/42')
        assert 'GL-43' in output
        prompt = (root / 'prompt').read_text()
        assert 'Use glab' in prompt and 'Merged: true' in prompt
        assert 'Follow-up evidence' in prompt and '+fixed' in prompt and 'GitLab omitted' in prompt
        assert 'Reviewed report' in run('show', 'GL-43')
        run('review', 'GL-42')
        assert 'Reviewed report' in run('show', 'GL-42')
        assert json.loads((root / 'issues.json').read_text())['42']['labels'] == ['security-advisory', 'cve']
        output = run('new', 'a'*40, expected=1, overrides={'FAIL_AI': '1'})
        recovery = re.search(r'Recovery files: (.+)', output).group(1)
        assert json.loads((Path(recovery) / 'session.json').read_text())['provider'] == 'gitlab'
        try:
            run('resume', recovery, overrides={'GSADV_PROVIDER': 'github', 'GSADV_REPO': 'wrong/repo', 'FAIL_AI': '1'})
        finally:
            # V uses /tmp on macOS even when TMPDIR is set. Remove only this run's session.
            if Path(recovery).exists():
                shutil.rmtree(recovery)
        assert calls()[-1]['client'] == 'glab' and calls()[-1]['host'] == 'gitlab.com'
        # A manual draft can be pasted and saved without fetching a source or running AI.
        manual = root / 'manual.md'
        manual.write_text('summary: Manual disclosure\nseverity: low\ncwe: CWE-125\ncredits:\n'
                          'package: parser\necosystem: other\naffected: < 2\npatched: 2\n---\n'
                          'Written by hand.\n')
        count = len(calls())
        editor = f'cp {shlex.quote(str(manual))}'
        output = run('new', overrides={'EDITOR': editor, 'GSADV_AI': 'false'})
        assert 'Opening edit.md' in output
        written = calls()[count:]
        assert len(written) == 1 and written[0]['method'] == 'POST', written
        assert written[0]['payload']['confidential'] is True
        created = next(i for i in json.loads((root / 'issues.json').read_text()).values()
                       if i['title'] == 'Manual disclosure')
        assert created['confidential'] is True and 'Written by hand.' in created['description']
        assert '403' in run('ls', expected=1, overrides={'FAIL_API': '1'})
        assert 'not this host' in run('--provider', 'gitlab', '-r', 'https://code.example/group/sub/repo', 'cve', 'GL-42')
        assert calls()[-1]['host'] == 'code.example'
        assert 'GitHub report' in run('-r', 'https://github.com/owner/repo', 'ls')
        for patched, status in [('1.2.0', '🟢'), ('2.0', '🔵'), ('3.0-rc1', '🟡'),
                                ('4.0', '🔴'), ('>= 1.2.0', '⚪'),
                                ('1.2.0; 2.0', '🟣')]:
            output = run('-r', 'https://github.com/owner/repo', 'ls', overrides={'PATCHED': patched})
            assert 'FIXED IN' in output and 'RELEASE' in output
            assert patched in output and status in output, output
            assert calls()[-1]['path'] == 'repos/owner/repo/releases?per_page=100'
        output = run('-r', 'https://github.com/owner/repo', 'ls',
                     overrides={'PATCHED': '1.2.0', 'FAIL_RELEASES': '1'})
        assert 'GitHub report' in output and '⚪' in output and '🔴' not in output
        output = run('-r', 'https://github.com/owner/repo', 'ls',
                     overrides={'PATCHED': '1.2.0', 'FAIL_RELEASES': 'silent'})
        assert 'GitHub report' in output and '⚪' in output and '🔴' not in output
        output = run('ls')
        assert '🟢' in output and '[confidential]' in output
        output = run('ls', overrides={'FAIL_RELEASES': '1'})
        assert '⚪' in output and '[confidential]' in output and '🔴' not in output
        run('-r', 'https://github.com/owner/repo', 'cve', 'GHSA-abcd-efgh-ijkl')
        assert 'requested*' in run('-r', 'https://github.com/owner/repo', 'ls')
        run('ls', overrides={'GSADV_REPO': 'owner/repo', 'GH_HOST': 'code.example'})
        assert calls()[-1]['client'] == 'gh' and calls()[-1]['host'] == 'code.example'
        assert 'https://code[.]example/' in calls()[-1]['args'][-1]
        if os.name == 'posix':
            tui_smoke(binary, root, env)
        print('Passed offline GitLab/GitHub CLI, source, mutation, recovery and local-tag checks.')


def tui_smoke(binary, root, env):
    import fcntl
    import pty
    import select
    import struct
    import termios

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 140, 0, 0))
    process = subprocess.Popen([binary], cwd=root, env=dict(env, TERM='xterm-256color'),
                               stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)

    def until(needle):
        output = b''
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                output += os.read(master, 65536)
                if needle.encode() in output:
                    return output.decode(errors='replace')
        raise AssertionError((needle, output.decode(errors='replace')))

    try:
        opening = until('[confidential]')
        assert 'FIXED IN' in opening and 'RELEASE' in opening and '🟢' in opening
        os.write(master, b'/')
        until('Filter text:')
        os.write(master, b'released\r')
        until('/released')
        os.write(master, b's')
        details = until('Affected:')
        assert 'Fixed in: 2 (released)' in details and 'parser: < 2' in details
        os.write(master, b'\x1b')
        until('disclosures')
        os.write(master, b'm')
        menu = until('Choose a key')
        assert 'CVE request instructions' in menu and 'p publish' not in menu
        os.write(master, b'c')
        until('No CVE request was submitted')
        os.write(master, b'\x1b')
        until('disclosures')
        os.write(master, b'i')
        until('Reason:')
        local_reason = ('Not shipped; introduced after the previous release and fixed before '
                        'the next release. ' * 3 + 'END OF SAVED REASON')
        os.write(master, (local_reason + '\r').encode())
        tagged = until('Local invalid tag (i reason, I clear): Not shipped')
        assert '[invalid]' not in tagged
        assert re.search(r'! .*GL-42', tagged), tagged
        os.write(master, b'i')
        saved = until('e: edit reason; Enter/Esc: back')
        assert 'Saved local invalid tag for GL-42' in saved and 'Not shipped' in saved
        assert 'END OF SAVED REASON' in saved
        os.write(master, b'e')
        until('Reason:')
        os.write(master, b'\x1b')
        until('Local invalid tag (i reason, I clear): Not shipped')
        os.write(master, b'I')
        until('Removed local invalid tag')
        os.write(master, b'\t')
        until('[commits')
        os.write(master, b'\t')
        issues = until('[issues ')
        assert 'Reviewed report' in issues and 'Fix parser' not in issues
        os.write(master, b'f')
        until('(opened)]')
        os.write(master, b'\t')
        mrs = until('[MRs ')
        assert 'Fix parser' in mrs and 'Reviewed report' not in mrs
        os.write(master, b'f')
        until('[MRs 0 (opened)]')
        os.write(master, b'f')
        until('[MRs 0 (closed)]')
        os.write(master, b'f')
        until('[MRs 1 (merged)]')
        os.write(master, b'\x1b[Z')
        issues = until('[issues ')
        assert '(opened)]' in issues and 'Reviewed report' in issues
        os.write(master, b'F')
        until('(all)]')
        os.write(master, b'\t')
        until('[MRs 1 (merged)]')
        os.write(master, b'f')
        until('[MRs 1 (all)]')
        os.write(master, b'r')
        until('Review source with AI.')
        os.write(master, b'\x1b')
        until('[MRs ')
        os.write(master, b'm')
        menu = until('Choose a key')
        assert 'M post discussion comment' in menu
        os.write(master, b'\x1b')
        until('[MRs ')
        os.write(master, b'/')
        until('Filter text:')
        os.write(master, b'Fix parser\r')
        until('/Fix parser')
        os.write(master, b'\t')
        until('[Reports ')
        os.write(master, b'\t')
        disclosures = until('[disclosures ')
        assert '/released' in disclosures and '/Fix parser' not in disclosures
        os.write(master, b'\x1b[Z')
        until('[Reports ')
        os.write(master, b'\x1b[Z')
        mrs = until('[MRs ')
        assert '/Fix parser' in mrs
        os.write(master, b'\x1b[Z')
        issues = until('[issues ')
        assert 'Reviewed report' in issues and 'Fix parser' not in issues
        # h/l and the arrows are aliases for shift-tab/tab.
        os.write(master, b'l')
        until('[MRs ')
        os.write(master, b'\x1b[D')
        until('[issues ')
        os.write(master, b'\x1b[C')
        until('[MRs ')
        os.write(master, b'h')
        until('[issues ')
        os.write(master, b',')
        until('label=cve')
        os.write(master, b'j\r')
        until('Set label in')
        os.write(master, b'\x15custom label\r')
        until('Saved label.')
        assert (root / '.gsadv.ini').read_text() == 'label=custom label\n'
        os.write(master, b'q')
        until('No entries. Press , to change the label setting')
        calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
        assert all('labels=custom+label' in c['path'] for c in calls[-2:])
        os.write(master, b'\t')
        until('[MRs 0')
        os.write(master, b',')
        until('label=custom label')
        os.write(master, b'j\r')
        until('Set label in')
        os.write(master, b'\x15\r')
        until('Saved label.')
        os.write(master, b'q')
        mrs = until('[MRs 1')
        assert '/Fix parser' in mrs
        calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
        assert all('labels=' not in c['path'] for c in calls[-2:])
        count = len(calls)
        os.write(master, b',')
        until('Settings |')
        os.write(master, b'j\r')
        until('Set label in')
        os.write(master, b'cancelled\x1b')
        until('Settings |')
        os.write(master, b'q')
        mrs = until('[MRs ')
        assert '/Fix parser' in mrs
        assert (root / '.gsadv.ini').read_text() == 'label=\n'
        assert len((root / 'calls').read_text().splitlines()) == count
        os.write(master, b'\x1b[Z')
        issues = until('[issues ')
        assert 'Reviewed report' in issues and 'Fix parser' not in issues
        os.write(master, b'q')
        assert process.wait(timeout=10) == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


if __name__ == '__main__':
    if Path(sys.argv[0]).name in ['glab', 'gh', 'agent', 'r2']:
        stub()
    else:
        main()

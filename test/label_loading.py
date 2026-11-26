#!/usr/bin/env python3
"""Check state queries, pagination and cached issue/PR/MR lists with stub gh/glab.

Usage: python3 test/label_loading.py /path/to/gsadv
"""

import json
from pathlib import Path
import sys
import tempfile
import time

from credits import Terminal


STUB = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
root = Path(os.environ['TEST_ROOT'])
args = sys.argv[1:]
if Path(sys.argv[0]).name == 'git':
    sys.exit(1)
assert args[0] == 'api' and '--method' not in args and '--input' not in args, args
path = next(a for a in args if a.startswith(('repos/', 'projects/')))
query = parse_qs(urlsplit(path).query)
label = query.get('labels', [''])[0]
state = query['state'][0]
kind = urlsplit(path).path.rsplit('/', 1)[-1]
if kind not in ('issues', 'merge_requests') or label == 'security-advisory':
    sys.exit(0)
client = Path(sys.argv[0]).name
page = int(query.get('page', ['1'])[0])
pages = range(page, 4) if '--paginate' in args and label == '' else [page]
for page in pages:
    fd = os.open(root / 'calls', os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(fd, (json.dumps(dict(label=label, state=state, page=page, kind=kind)) + '\n').encode())
    os.close(fd)
    deadline = time.monotonic() + 15
    late_pull = (root / 'late-pull').exists() and label == '' and page == 1
    blocked = label == '' and (page == 2 or (late_pull and kind == 'merge_requests'))
    while blocked and (root / 'hold-page').exists():
        assert time.monotonic() < deadline, 'blocked fixture timed out'
        time.sleep(0.01)
    if label == '' and page == 2 and (root / 'fail-page').exists():
        sys.exit('HTTP 503: fixture page unavailable')
    if state == 'closed':
        continue
    rows = []
    if client == 'gh' or kind == 'merge_requests':
        if label == 'security':
            rows = [(900, 'Labelled pull')]
        elif label == 'other label':
            rows = [(901, 'Other label pull')]
        elif label == '':
            count = int((root / 'count').read_text())
            rows = [(i, f'Unfiltered pull {i}')
                    for i in range((page - 1) * 100 + 1, min(page * 100, count) + 1)]
    if late_pull and kind == 'issues':
        rows = [(i, f'Unfiltered issue {i}') for i in range(1, 101)]
    for number, title in rows:
        url = f'https://github.com/owner/repo/pull/{number}' if client == 'gh' else (
            f'https://gitlab.com/owner/repo/-/merge_requests/{number}')
        if client == 'gh':
            row_kind = 'issue' if late_pull else 'PR'
            print(f'{url}\t{number}\t{row_kind}\topen\t{title}')
        else:
            print(json.dumps(dict(web_url=url, iid=number, state='opened', title=title)))
'''


def calls(root):
    return [json.loads(line) for line in (root / 'calls').read_text().splitlines()]


def wait_for_page(ui, root, page, start=0):
    deadline = time.monotonic() + 5
    while not any(c['label'] == '' and c['page'] == page for c in calls(root)[start:]):
        assert ui.process.poll() is None, ui.buffer
        assert time.monotonic() < deadline, ui.buffer
        ui.read(0.01)


def set_label(ui, label):
    ui.send(',')
    ui.expect('Settings |')
    ui.send('j\r')
    ui.expect('Set label in')
    ui.send('\x15' + label + '\r')
    ui.expect('Saved label.')
    ui.send('q')


def checks(binary, root, provider, scenario):
    for name in ('gh', 'glab', 'git'):
        (root / name).write_text(STUB)
        (root / name).chmod(0o700)
    # 200 exercises an exactly full last page followed by an empty page.
    count = 200 if scenario == 'complete' else 201
    (root / 'count').write_text(str(count))
    (root / 'hold-page').touch()
    if scenario == 'late-pull':
        (root / 'late-pull').touch()
    title = 'PRs' if provider == 'github' else 'MRs'
    state = 'open' if provider == 'github' else 'opened'
    env = {'GSADV_PROVIDER': provider, 'GSADV_LABEL': 'security'}
    with Terminal(binary, root, 'tui', size=(200, 30), extra_env=env) as ui:
        ui.expect(f'{title} 1 ({state})')
        assert {c['state'] for c in calls(root)} == {state}
        if provider == 'github':
            assert len(calls(root)) == 1
        ui.send('\t\t\t')
        ui.expect('Labelled pull')
        set_label(ui, '')
        if scenario == 'late-pull':
            screen = ui.expect(f'[{title} 0 ({state}) loading...]')
            ui.expect('Loading... You can switch tabs or quit while requests run.')
            assert 'No entries.' not in screen
            wait_for_page(ui, root, 2)
            ui.send('\x1b[Z')
            ui.expect(f'[issues 100 ({state}) loading...]')
            ui.expect('Unfiltered issue 1')
            ui.send('\t')
            ui.expect(f'[{title} 0 ({state}) loading...]')
            (root / 'hold-page').unlink()
            ui.expect(f'[{title} {101 if provider == "github" else count} ({state})]')
            ui.send('q')
            ui.finish()
            return
        ui.expect(f'[{title} 100 ({state}) loading...]')
        ui.expect('Unfiltered pull 1')
        wait_for_page(ui, root, 2)
        # Navigation and text filtering work while the next page is blocked.
        ui.send('/')
        ui.expect('Filter text:')
        ui.send('Unfiltered pull 10\r')
        ui.expect(f'[{title} 2 ({state}) loading...]')
        ui.send('/')
        ui.expect('Filter text:')
        ui.send('\r')
        ui.expect(f'[{title} 100 ({state}) loading...]')
        if scenario == 'change':
            set_label(ui, 'intermediate')
            set_label(ui, 'other label')
            (root / 'hold-page').unlink()
            ui.expect(f'[{title} 1 ({state})]')
            ui.expect('Other label pull')
            # A full repaint cannot contain rows from the abandoned label.
            ui.send('\t')
            ui.expect('[Reports ')
            ui.send('\x1b[Z')
            screen = ui.expect('Other label pull')
            assert 'Unfiltered pull' not in screen and 'Labelled pull' not in screen
            paged_kind = 'issues' if provider == 'github' else 'merge_requests'
            assert not any(c['label'] == 'intermediate' and c['kind'] == paged_kind for c in calls(root))
            assert not any(c['label'] == '' and c['page'] > 2 for c in calls(root))
        elif scenario == 'failure':
            (root / 'fail-page').touch()
            (root / 'hold-page').unlink()
            ui.expect('HTTP 503: fixture page unavailable')
            ui.send('\t')
            ui.expect('[Reports ')
            ui.send('\x1b[Z')
            ui.expect(f'[{title} 100 ({state})]')
            ui.expect('Unfiltered pull 1')
        else:
            (root / 'hold-page').unlink()
            ui.expect(f'[{title} {count} ({state})]')
            assert {c['page'] for c in calls(root) if c['label'] == ''} == {1, 2, 3}
            ui.send('/')
            ui.expect('Filter text:')
            ui.send('Unfiltered pull 200\r')
            ui.expect(f'[{title} 1 ({state})]')
            ui.expect('Unfiltered pull 200')
            # A refresh must retain the complete list and a late-page selection,
            # including when a subsequent page fails.
            before = len(calls(root))
            (root / 'hold-page').touch()
            ui.send('\x12')
            wait_for_page(ui, root, 2, start=before)
            ui.send('\t')
            ui.expect('[Reports ')
            ui.send('\x1b[Z')
            ui.expect(f'[{title} 1 ({state})]')
            ui.expect('Unfiltered pull 200')
            (root / 'fail-page').touch()
            (root / 'hold-page').unlink()
            ui.expect('HTTP 503: fixture page unavailable')
            ui.send('/')
            ui.expect('Filter text:')
            ui.send('\r')
            ui.expect(f'[{title} {count} ({state})]')
        ui.send('q')
        ui.finish()
    if scenario != 'complete':
        return

    # A new process can browse the complete snapshot while its refresh is blocked.
    (root / 'fail-page').unlink()
    (root / 'hold-page').touch()
    (root / 'count').write_text(str(count - 1))
    before = len(calls(root))
    cache_files = list((root / 'cache' / 'gsadv' / 'issues-v1').glob('*.json'))
    assert cache_files and all(p.stat().st_mode & 0o777 == 0o600 for p in cache_files)
    with Terminal(binary, root, 'tui', size=(200, 30), extra_env=dict(env, GSADV_LABEL='')) as ui:
        ui.expect(f'{title} {count} ({state})')
        wait_for_page(ui, root, 2, start=before)
        ui.send('\t\t\t')
        ui.expect(f'[{title} {count} ({state})]')
        ui.send('G')
        ui.expect(f'Unfiltered pull {count}')
        (root / 'hold-page').unlink()
        ui.expect(f'[{title} {count - 1} ({state})]')
        ui.send('f')
        ui.expect(f'[{title} 0 (closed)]')
        assert {c['state'] for c in calls(root)[before:]} == {state, 'closed'}
        ui.send('F')
        ui.expect(f'[{title} {count - 1} ({state})]')
        ui.send('q')
        ui.finish()


if __name__ == '__main__':
    binary = str(Path(sys.argv[1]).resolve())
    for provider in ('github', 'gitlab'):
        for scenario in ('change', 'complete', 'failure', 'late-pull'):
            with tempfile.TemporaryDirectory(prefix='gsadv-label-loading-') as tmp:
                checks(binary, Path(tmp), provider, scenario)
    print('Incremental loading, label changes, pagination and page failure checks passed')

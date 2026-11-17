#!/usr/bin/env python3
"""Check incremental issue/PR/MR loading with stub gh/glab and a blocked page.

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
kind = urlsplit(path).path.rsplit('/', 1)[-1]
if kind not in ('issues', 'merge_requests') or label == 'security-advisory':
    sys.exit(0)
client = Path(sys.argv[0]).name
page = int(query.get('page', ['1'])[0])
pages = range(page, 4) if '--paginate' in args and label == '' else [page]
for page in pages:
    fd = os.open(root / 'calls', os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(fd, (json.dumps(dict(label=label, page=page, kind=kind)) + '\n').encode())
    os.close(fd)
    deadline = time.monotonic() + 15
    while label == '' and page == 2 and (root / 'hold-page').exists():
        assert time.monotonic() < deadline, 'blocked fixture timed out'
        time.sleep(0.01)
    if label == '' and page == 2 and (root / 'fail-page').exists():
        sys.exit('HTTP 503: fixture page unavailable')
    rows = []
    late_pull = (root / 'late-pull').exists() and label == '' and page == 1
    if client == 'gh' or kind == 'merge_requests':
        if label == 'security':
            rows = [(900, 'Labelled pull')]
        elif label == 'other label':
            rows = [(901, 'Other label pull')]
        elif label == '':
            count = int((root / 'count').read_text())
            rows = [(i, f'Unfiltered pull {i}')
                    for i in range((page - 1) * 100 + 1, min(page * 100, count) + 1)]
    if late_pull:
        rows = [(i, f'Unfiltered issue {i}') for i in range(1, 101)] if kind == 'issues' else []
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
    ui.send('l')
    ui.expect('Label: ')
    ui.send('\x15' + label + '\r')


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
    with Terminal(binary, root, 'tui', size=(200, 30), extra_env={
            'GSADV_PROVIDER': provider, 'GSADV_LABEL': 'security'}) as ui:
        ui.expect(f'{title} 1 (label: security)')
        ui.send('\t\t\t')
        ui.expect('Labelled pull')
        set_label(ui, '')
        if scenario == 'late-pull':
            screen = ui.expect(f'[{title} 0 (all labels) loading...]')
            ui.expect('Loading... You can switch tabs or quit while requests run.')
            assert 'No entries.' not in screen
            wait_for_page(ui, root, 2)
            ui.send('\x1b[Z')
            ui.expect('[issues 100 (all labels) loading...]')
            ui.expect('Unfiltered issue 1')
            ui.send('\t')
            ui.expect(f'[{title} 0 (all labels) loading...]')
            (root / 'hold-page').unlink()
            ui.expect(f'[{title} 101 (all labels)]')
            ui.send('q')
            ui.finish()
            return
        ui.expect(f'[{title} 100 (all labels) loading...]')
        ui.expect('Unfiltered pull 1')
        wait_for_page(ui, root, 2)
        # Navigation and text filtering work while the next page is blocked.
        ui.send('/')
        ui.expect('Filter text:')
        ui.send('Unfiltered pull 10\r')
        ui.expect(f'[{title} 2 (all labels) loading...]')
        ui.send('/')
        ui.expect('Filter text:')
        ui.send('\r')
        ui.expect(f'[{title} 100 (all labels) loading...]')
        if scenario == 'change':
            set_label(ui, 'intermediate')
            ui.expect('label: intermediate')
            set_label(ui, 'other label')
            ui.expect('label: other label')
            (root / 'hold-page').unlink()
            ui.expect(f'[{title} 1 (label: other label)]')
            ui.expect('Other label pull')
            # A full repaint cannot contain rows from the abandoned label.
            ui.send('\t')
            ui.expect('[advisories ' if provider == 'github' else '[disclosures ')
            ui.send('\x1b[Z')
            screen = ui.expect('Other label pull')
            assert 'Unfiltered pull' not in screen and 'Labelled pull' not in screen
            assert not any(c['label'] == 'intermediate' for c in calls(root))
            assert not any(c['label'] == '' and c['page'] > 2 for c in calls(root))
        elif scenario == 'failure':
            (root / 'fail-page').touch()
            (root / 'hold-page').unlink()
            ui.expect('HTTP 503: fixture page unavailable')
            ui.send('\t')
            ui.expect('[advisories ' if provider == 'github' else '[disclosures ')
            ui.send('\x1b[Z')
            ui.expect(f'[{title} 100 (all labels)]')
            ui.expect('Unfiltered pull 1')
        else:
            (root / 'hold-page').unlink()
            ui.expect(f'[{title} {count} (all labels)]')
            assert {c['page'] for c in calls(root) if c['label'] == ''} == {1, 2, 3}
            ui.send('/')
            ui.expect('Filter text:')
            ui.send('Unfiltered pull 200\r')
            ui.expect(f'[{title} 1 (all labels)]')
            ui.expect('Unfiltered pull 200')
            # A refresh must retain the complete list and a late-page selection,
            # including when a subsequent page fails.
            before = len(calls(root))
            (root / 'hold-page').touch()
            ui.send('g')
            wait_for_page(ui, root, 2, start=before)
            ui.send('\t')
            ui.expect('[advisories ' if provider == 'github' else '[disclosures ')
            ui.send('\x1b[Z')
            ui.expect(f'[{title} 1 (all labels)]')
            ui.expect('Unfiltered pull 200')
            (root / 'fail-page').touch()
            (root / 'hold-page').unlink()
            ui.expect('HTTP 503: fixture page unavailable')
            ui.send('/')
            ui.expect('Filter text:')
            ui.send('\r')
            ui.expect(f'[{title} {count} (all labels)]')
        ui.send('q')
        ui.finish()


if __name__ == '__main__':
    binary = str(Path(sys.argv[1]).resolve())
    for provider in ('github', 'gitlab'):
        for scenario in ('change', 'complete', 'failure', 'late-pull'):
            with tempfile.TemporaryDirectory(prefix='gsadv-label-loading-') as tmp:
                checks(binary, Path(tmp), provider, scenario)
    print('Incremental loading, label changes, pagination and page failure checks passed')

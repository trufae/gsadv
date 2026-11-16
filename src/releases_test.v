module main

import term
import time

fn test_fixed_versions_require_release_evidence() {
	releases := {'v1.2.0': 'released', '2.0': 'draft', 'v3.0-rc1': 'prerelease',
		'4.0': 'upcoming', 'project-5': 'released'}
	for patched in ['1.2.0', 'v1.2.0', 'V1.2.0', ' 1.2.0 '] {
		assert fixed_release_state(patched, releases, true) == 'released'
	}
	assert fixed_release_state('v2.0', releases, true) == 'draft'
	assert fixed_release_state('3.0-rc1', releases, true) == 'prerelease'
	assert fixed_release_state('4.0', releases, true) == 'upcoming'
	assert fixed_release_state('project-5', releases, true) == 'released'
	assert fixed_release_state('1.1.0', releases, true) == 'no release'
	assert fixed_release_state('1.2.0', {}, true) == 'no release'
	assert fixed_release_state('1.2.0', releases, false) == 'unknown'
	for patched in ['', '-', 'unknown', '>= 1.2.0', '1.2.0, 2.0', 'master', 'none'] {
		assert fixed_release_state(patched, releases, true) == 'unknown'
	}
	status, detail := fixed_release_summary('1.2.0; 2.0; 1.2.0', releases, '')
	assert status == 'mixed'
	assert detail == '1.2.0 (released); 2.0 (draft)'
	failed, reason := fixed_release_summary('1.2.0; 2.0', releases, 'HTTP 403\nDenied')
	assert failed == 'unknown'
	assert reason.contains('1.2.0 (unknown)') && reason.contains('HTTP 403 Denied')
}

fn test_gitlab_future_releases_are_not_released() ! {
	now := time.parse_rfc3339('2026-01-01T00:00:00Z')!
	assert gitlab_release_state(GitLabRelease{released_at: '2025-12-31T23:59:59Z'}, now) == 'released'
	assert gitlab_release_state(GitLabRelease{released_at: '2026-01-01T00:00:00Z'}, now) == 'released'
	assert gitlab_release_state(GitLabRelease{released_at: '2026-01-01T00:00:01Z'}, now) == 'upcoming'
	assert gitlab_release_state(GitLabRelease{upcoming_release: true}, now) == 'upcoming'
	assert gitlab_release_state(GitLabRelease{}, now) == 'unknown'
}

fn test_fixed_version_columns_filter_and_refresh() {
	mut a := ['GHSA-abcd-efgh-ijkl', 'draft', '-', 'high', 'Bounds check', 'abcdef1234', '', '',
		'1.2.0', 'parser: < 1.2.0', 'no release', '1.2.0 (no release)']
	for width in [80, 119, 120, 160, 999] {
		line := term.strip_ansi(row(a, width))
		header := advisory_columns(width)
		assert line.contains('1.2.0') && line.contains('🔴')
		assert !line.contains('no release')
		assert !line.contains('[]')
		mut offset := 0
		for g in line.all_before('1.2.0').graphemes() { offset += cell_width(g) }
		assert offset == header.index('FIXED IN') or { -1 }
		for label, value in {'RELEASE': '🔴', 'SUMMARY': 'Bounds check'} {
			offset = 0
			for g in line.all_before(value).graphemes() { offset += cell_width(g) }
			assert offset == header.index(label) or { -1 }
		}
		assert header.contains('CVE') == (width >= 120)
	}
	mut list := TuiList{}
	list.rebuild([a], [a], advisory_links([a]), 0)
	list.filter([a], 'no release', 'draft')
	assert list.visible == [0]
	assert list.line(0, [a], [a], 0, 80, false).contains('🔴')
	a[10], a[11] = 'released', '1.2.0 (released)'
	list.rebuild([a], [a], advisory_links([a]), 0)
	list.filter([a], 'no release', 'draft')
	assert list.visible == []int{}
	list.filter([a], '1.2.0', 'all')
	assert list.visible == [0]
	assert list.line(0, [a], [a], 0, 80, false).contains('🟢')
	assert release_hint(a).contains('Affected: parser: < 1.2.0')
	assert row(['GHSA-test', 'draft', '-', 'high', 'Report'], 120).contains('unknown')
	a[2] = 'CVE-2026-123456789,CVE-2026-987654321'
	assert row(a, 120).contains('1.2.0') && row(a, 120).contains('🟢')
	a[8] = '1.2.0; 2.0.0; 3.0.0'
	assert row(a, 80).contains('…')
	assert row(a, 999).contains(a[8])
}

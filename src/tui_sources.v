module main

import crypto.sha256
import json2
import os
import rand
import time

fn (api Repository) issue_query(label string, view int, filter int) IssueQuery {
	kind := if api.provider == 'github' { IssueKind.mixed } else if view == 2 { IssueKind.issues } else { IssueKind.pulls }
	return IssueQuery{label, api.tui_states(view)[filter], kind}
}

fn (api Repository) issue_cache_path(query IssueQuery) string {
	configured := os.getenv('XDG_CACHE_HOME')
	base := if configured != '' { configured } else { os.join_path(os.home_dir(), '.cache') }
	identity := json2.encode([api.provider, api.host, api.repo, query.label, query.state, query.kind.str()])
	return os.join_path(base, 'gsadv', 'issues-v1', sha256.hexhash(identity) + '.json')
}

fn save_issue_cache(path string, rows [][]string) ! {
	os.mkdir_all(os.dir(path), mode: 0o700)!
	tmp := '${path}.${rand.ulid()}.tmp'
	mut file := os.open_file(tmp, 'wb', 0o600)!
	defer { os.rm(tmp) or {} }
	file.write_string(json2.encode(rows)) or {
		file.close()
		return err
	}
	file.close()
	os.rename(tmp, path)!
}

struct TuiIssuePage {
	query IssueQuery
	page int
	rows [][]string
	more bool
	error string
}

fn load_issue_page(api Repository, query IssueQuery, page int, results chan TuiIssuePage) {
	rows, more := api.issue_page(query, page) or {
		results <- TuiIssuePage{query: query, page: page, error: err.msg()}
		return
	}
	results <- TuiIssuePage{query: query, page: page, rows: rows, more: more}
}

struct TuiIssueList {
	query IssueQuery
mut:
	page int = 1
	started time.Time = time.now()
	done bool
	retain bool
	rows [][]string
	incoming [][]string
	revision int
}

struct TuiSourceLoader {
	results chan TuiIssuePage = chan TuiIssuePage{cap: 2}
mut:
	lists []TuiIssueList
	pending []IssueQuery
	revision int
}

fn (loader TuiSourceLoader) list(query IssueQuery) ?TuiIssueList {
	for list in loader.lists {
		if list.query == query { return list }
	}
	return none
}

fn (mut loader TuiSourceLoader) request(api Repository, label string, filters []int, reload bool) {
	queries := [api.issue_query(label, 2, filters[2]), api.issue_query(label, 3, filters[3])]
	mut lists := []TuiIssueList{}
	for i, query in queries {
		if i == 1 && query == queries[0] { continue }
		mut list := loader.list(query) or {
			loader.revision++
			mut cached := TuiIssueList{query: query, revision: loader.revision}
			if content := os.read_file(api.issue_cache_path(query)) {
				if rows := json2.decode[[][]string](content) {
					cached.rows, cached.retain = rows, true
				}
			}
			cached
		}
		if reload && list.done {
			list.page, list.done = 1, false
			list.started = time.now()
			list.retain = list.retain || list.rows.len > 0
		}
		lists << list
	}
	loader.lists = lists
	loader.schedule(api)
}

fn (mut loader TuiSourceLoader) schedule(api Repository) {
	for list in loader.lists {
		if list.done || list.query in loader.pending { continue }
		// GitHub shares pages across tabs with the same filter. GitLab issues and
		// MRs paginate independently, including when an old query is finishing.
		if list.query.kind == .mixed {
			if loader.pending.len >= loader.lists.len { break }
		} else if loader.pending.any(it.kind == list.query.kind) {
			continue
		}
		loader.pending << list.query
		spawn load_issue_page(api, list.query, list.page, loader.results)
	}
}

fn (mut loader TuiSourceLoader) poll(api Repository) string {
	mut failure := ''
	mut result := TuiIssuePage{}
	for loader.results.try_pop(mut result) == .success {
		index := loader.pending.index(result.query)
		if index >= 0 { loader.pending.delete(index) }
		for mut list in loader.lists {
			// A superseded query stops after its current page. A query selected
			// again while its old page is pending starts over at page one.
			if list.query != result.query || list.page != result.page { continue }
			if result.error == '' {
				if list.retain {
					list.incoming << result.rows
					if !result.more && list.rows != list.incoming {
						list.rows = list.incoming
						loader.revision++
						list.revision = loader.revision
					}
				} else if result.rows.len > 0 {
					list.rows << result.rows
					loader.revision++
					list.revision = loader.revision
				}
				if result.more {
					list.page++
					list.started = time.now()
					continue
				}
				list.retain = true
				save_issue_cache(api.issue_cache_path(list.query), list.rows) or {}
			} else if failure == '' {
				failure = 'issues: ' + result.error.replace('\n', ' ')
			}
			list.incoming = [][]string{}
			list.done = true
		}
	}
	loader.schedule(api)
	return failure
}

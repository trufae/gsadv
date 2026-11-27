module main

const states = ['all', 'triage', 'draft', 'published', 'closed']

const format = $embed_file('prompts/format.txt').to_string().trim_right('\n')

fn advisory_template(name string) string {
	return '# Fill in the fields and sections below, or paste a complete advisory in this format.
# Save and close to create a draft; leave unchanged or empty the file to cancel.
# severity: low, medium, high or critical. A CVSS:3.1/... vector overrides severity.
# cwe: CWE-nnn, ...; credits: login:finder, login:reporter, login:remediation_developer
summary:
severity:
cvss:
cwe:
credits:
package: ${name}
ecosystem: other
affected:
patched:
---
## Impact

<Who is affected, attack preconditions, impact and its limits.>

## Details

<Root cause, affected functions and when the vulnerable code was introduced.>

## Proof of concept

<Reproduction steps, input or commands, and observed results.>

## Patches

<Fix commits and the first patched release, or explain what is unknown.>

## Workarounds

<Available mitigations, or state that none are known.>

## References

<Links to the report, fix, related advisories and any assigned CVE.>

## Acknowledgements

<Verified finder, reporter, fix author and tool attribution.>
'
}

struct Pkg {
	ecosystem string
	name      string
}

struct Vuln {
mut:
	package                  Pkg
	vulnerable_version_range string @[omitempty]
	patched_versions         string @[omitempty]
}

struct Credit {
	login string
	typ   string @[json: 'type']
}

struct CreditRole {
	typ         string
	description string
}

// GitHub repository advisory credit types. Keep their API spellings in one place.
const credit_roles = [
	CreditRole{'finder', 'Discovered the vulnerability'},
	CreditRole{'reporter', 'Reported the vulnerability'},
	CreditRole{'analyst', 'Analyzed or documented the vulnerability'},
	CreditRole{'coordinator', 'Coordinated disclosure and response'},
	CreditRole{'remediation_developer', 'Developed the fix'},
	CreditRole{'remediation_reviewer', 'Reviewed the fix'},
	CreditRole{'remediation_verifier', 'Verified that the fix works'},
	CreditRole{'tool', 'Tool used to discover or investigate the bug'},
	CreditRole{'sponsor', 'Supported or funded the work'},
	CreditRole{'other', 'Another contribution'},
]

fn credit_description(typ string) string {
	for role in credit_roles {
		if role.typ == typ { return role.description }
	}
	return 'Unknown role: ${typ}'
}

// A person can hold several roles, but each login/role pair must be unique.
fn change_credit(credits []Credit, index int, input Credit) ![]Credit {
	login := input.login.trim_space().trim_string_left('@')
	name := login.trim_string_right('[bot]')
	if name == '' || !name.bytes().all(it.is_alnum() || it == `-`) {
		return error('enter a GitHub username, optionally starting with @')
	}
	if !credit_roles.any(it.typ == input.typ) {
		return error('choose a credit role from the list')
	}
	if index < -1 || index >= credits.len {
		return error('no credit selected')
	}
	for i, item in credits {
		if i != index && item.login.to_lower() == login.to_lower() && item.typ == input.typ {
			return error('@${login} already has the ${input.typ} credit')
		}
	}
	mut result := credits.clone()
	value := Credit{login, input.typ}
	if index == -1 { result << value } else { result[index] = value }
	return result
}

struct Adv {
mut:
	summary            string
	description        string
	severity           string @[omitempty]
	cvss_vector_string string @[omitempty]
	cwe_ids            []string
	credits            []Credit
	vulnerabilities    []Vuln
}

fn csv(s string) []string {
	return s.split(',').map(it.trim_space()).filter(it != '')
}

// Compare editable values, ignoring the order of sets and GitHub username casing.
fn advisory_changes(a Adv, b Adv) []string {
	mut fields := []string{}
	if a.summary != b.summary { fields << 'summary' }
	if a.description != b.description { fields << 'description' }
	if a.severity != b.severity { fields << 'severity' }
	if a.cvss_vector_string != b.cvss_vector_string { fields << 'cvss' }
	if a.cwe_ids.sorted() != b.cwe_ids.sorted() { fields << 'cwe' }
	if a.credits.map(it.login.to_lower() + ':' + it.typ).sorted()
		!= b.credits.map(it.login.to_lower() + ':' + it.typ).sorted() {
		fields << 'credits'
	}
	if a.vulnerabilities.map(it.str()).sorted() != b.vulnerabilities.map(it.str()).sorted() {
		fields << 'vulnerabilities'
	}
	return fields
}

fn parse(text string) !Adv {
	sep := text.index('\n---\n') or { return error('missing --- separator') }
	mut a := Adv{
		description: text[sep + 5..].trim_space().trim_string_right('```').trim_space()
	}
	for line in text[..sep].split_into_lines() {
		l := line.trim_space()
		if l == '' || l.starts_with('#') {
			continue
		}
		k := l.all_before(':').trim_space()
		v := l.all_after_first(':').trim_space()
		if k in ['ecosystem', 'affected', 'patched', 'functions'] && a.vulnerabilities.len == 0 {
			return error('${k}: must follow a package: line')
		}
		mut last := if a.vulnerabilities.len > 0 {
			&a.vulnerabilities[a.vulnerabilities.len - 1]
		} else {
			unsafe { nil }
		}
		match k {
			'summary' { a.summary = v }
			'severity' { a.severity = v }
			'cvss' { a.cvss_vector_string = v }
			'cwe' { a.cwe_ids = csv(v) }
			'credits' {
				a.credits = csv(v).map(Credit{it.all_before(':'), if it.contains(':') {
					it.all_after_first(':')
				} else {
					'finder'
				}})
			}
			'package' { a.vulnerabilities << Vuln{ package: Pkg{'other', v} } }
			'ecosystem' { last.package = Pkg{v, last.package.name} }
			'affected' { last.vulnerable_version_range = v }
			'patched' { last.patched_versions = v }
			'functions' {
				// GitHub accepts vulnerable_functions but never stores them.
				if v != '' {
					return error('functions: GitHub does not store vulnerable functions; name them in the description')
				}
			}
			else { return error('unknown field: ${k}') }
		}
	}
	if a.summary == '' || a.description == '' {
		return error('summary and description are required')
	}
	if a.cvss_vector_string != '' {
		a.severity = '' // github rejects both
	}
	return a
}

// URL references link issues/PRs. Commit SHAs take precedence over finding IDs.
// Build once per advisory snapshot, so list navigation never scans descriptions.
struct AdvisoryLinks {
mut:
	references map[string]int
	urls map[string]int
}

fn advisory_links(advs [][]string) AdvisoryLinks {
	mut links := AdvisoryLinks{}
	for i, a in advs {
		if a.len > 5 {
			for reference in a[5].split(',') {
				if reference != '' && reference !in links.references { links.references[reference] = i }
			}
		}
		if a.len > 6 {
			for url in a[6].to_lower().split(',') {
				if url != '' && url !in links.urls { links.urls[url] = i }
			}
		}
	}
	return links
}

fn (links AdvisoryLinks) find(input string, findings ...string) int {
	if input.starts_with('https://') { return links.urls[input.to_lower()] or { -1 } }
	mut first := -1
	for end in 1 .. input.len + 1 {
		if i := links.references[input[..end]] {
			if first < 0 || i < first { first = i }
		}
	}
	if first >= 0 { return first }
	finding := findings[0] or { return -1 }
	return links.references[finding] or { -1 }
}

fn adv_of_commit(advs [][]string, commit []string) int {
	linked := adv_of(advs, commit[0] or { '' })
	if linked >= 0 { return linked }
	finding := commit[4] or { return -1 }
	if finding == '' { return -1 }
	for i, a in advs {
		if a.len > 5 && finding in a[5].split(',') { return i }
	}
	return -1
}

fn adv_of(advs [][]string, input string) int {
	if input == '' {
		return -1
	}
	for i, a in advs {
		if input.starts_with('https://') {
			if a.len > 6 && a[6].split(',').any(it.to_lower() == input.to_lower()) {
				return i
			}
		} else if a.len > 5 && a[5].split(',').any(it != '' && input.starts_with(it)) {
			return i
		}
	}
	return -1
}

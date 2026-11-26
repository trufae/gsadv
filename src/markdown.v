module main

import strings
import term
import x.markdown

fn color_markdown(text string) string {
	mut md := markdown.Markdown.new(extensions: markdown.gfm())
	doc := md.parse(text)
	return markdown_block(doc, md)
}

fn markdown_style(text string, style string) string {
	visible := text.replace('\x1b', r'\x1b')
	return if style == '0' || visible == '' {
		visible
	} else {
		visible.split('\n').map(term.format(it, style, '0')).join('\n')
	}
}

fn markdown_inline(nodes []&markdown.Node, style string) string {
	mut out := strings.new_builder(64)
	mut literal := strings.new_builder(64)
	for node in nodes {
		if node.kind in [.text, .raw_html] {
			literal.write_string(node.literal)
			continue
		}
		if literal.len > 0 { out.write_string(markdown_style(literal.str(), style)) }
		part := match node.kind {
			.code_span { markdown_style('`${node.literal}`', style + ';33') }
			.emphasis { markdown_inline(node.children, style + ';3') }
			.strong { markdown_inline(node.children, style + ';1') }
			.strikethrough { markdown_inline(node.children, style + ';9') }
			.autolink { markdown_style(node.literal, style + ';4;36') }
			.link, .image {
				label := markdown_inline(node.children, style + ';4;36')
				if node.dest == '' {
					label
				} else if label == '' {
					markdown_style(node.dest, style + ';4;36')
				} else {
					label + markdown_style(' (${node.dest})', style + ';36')
				}
			}
			.hard_break, .soft_break { '\n' }
			.task_checkbox {
				if node.checked { '[x] ' } else { '[ ] ' }
			}
			else { markdown_inline(node.children, style) }
		}
		out.write_string(part)
	}
	if literal.len > 0 { out.write_string(markdown_style(literal.str(), style)) }
	return out.str()
}

fn markdown_block(node &markdown.Node, md &markdown.Markdown) string {
	match node.kind {
		.heading, .paragraph, .table_cell {
			style := if node.kind == .heading { '1;36' } else { '0' }
			prefix := if node.kind == .heading {
				markdown_style('${'#'.repeat(node.level)} ', style)
			} else {
				''
			}
			return prefix + markdown_inline(markdown.parse_inline(node.literal, md.opts, md.ref_map), style)
		}
		.fenced_code {
			code := markdown_style(node.literal.trim_string_right('\n'), '33')
			return markdown_style('```${node.fence_info}', '2') + '\n' + code + '\n' + markdown_style('```', '2')
		}
		.code_block {
			return node.literal.split_into_lines().map(markdown_style('    ${it}', '33')).join('\n')
		}
		.thematic_break { return markdown_style('---', '2') }
		.html_block { return node.literal.trim_right('\n') }
		.blockquote {
			inner := node.children.map(markdown_block(it, md)).join('\n\n')
			return inner.split('\n').map(markdown_style('> ', '2') + it).join('\n')
		}
		.list {
			mut items := []string{cap: node.children.len}
			for i, item in node.children {
				marker := if node.is_ordered { '${node.list_start + i}. ' } else { '- ' }
				item_text := item.children.map(markdown_block(it, md)).join(if node.is_tight {
					'\n'
				} else {
					'\n\n'
				})
				items << markdown_style(marker, '36') + item_text.replace('\n', '\n' + ' '.repeat(marker.len))
			}
			return items.join(if node.is_tight { '\n' } else { '\n\n' })
		}
		.table_row { return '| ' + node.children.map(markdown_block(it, md)).join(' | ') + ' |' }
		.table, .table_head, .table_body {
			return node.children.map(markdown_block(it, md)).join('\n')
		}
		else { return node.children.map(markdown_block(it, md)).join('\n\n') }
	}
}

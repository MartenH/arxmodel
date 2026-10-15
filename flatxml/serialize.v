module flatxml

import strings

// inner_xml is element i's content written back as XML: child elements with their attributes,
// and text, escaped. It is a re-serialisation of the tree, not a copy of the source: comments,
// processing instructions, CDATA sections, entity spellings and whitespace between tags are not
// kept, and neither are namespace declarations made on ancestors of i.
pub fn (d &Doc) inner_xml(i u32) string {
	mut sb := strings.new_builder(64)
	d.write_content(mut sb, i)
	return sb.str()
}

fn (d &Doc) write_content(mut sb strings.Builder, i u32) {
	if d.text_len[i] != 0 {
		write_escaped(mut sb, d.text(i), false)
		return
	}
	mut c := d.first_child(i)
	// Each child in document order: text as it reads, an element with its content.
	for c != no_node {
		if d.is_text(c) {
			write_escaped(mut sb, d.text(c), false)
		} else {
			sb.write_u8(`<`)
			sb.write_string(d.name(c))
			lo, hi := d.attr_range(c)
			for a := lo; a < hi; a++ {
				sb.write_u8(` `)
				sb.write_string(d.attr_name(a))
				sb.write_string('="')
				write_escaped(mut sb, d.attr_value(a), true)
				sb.write_u8(`"`)
			}
			if d.first_child(c) == no_node && d.text_len[c] == 0 {
				sb.write_string('/>')
			} else {
				sb.write_u8(`>`)
				d.write_content(mut sb, c)
				sb.write_string('</')
				sb.write_string(d.name(c))
				sb.write_u8(`>`)
			}
		}
		c = d.next_sibling(c)
	}
}

fn write_escaped(mut sb strings.Builder, s string, attr bool) {
	for b in s {
		match b {
			`&` { sb.write_string('&amp;') }
			`<` { sb.write_string('&lt;') }
			`>` { sb.write_string('&gt;') }
			`"` { if attr { sb.write_string('&quot;') } else { sb.write_u8(b) } }
			`\t` { if attr { sb.write_string('&#9;') } else { sb.write_u8(b) } }
			`\n` { if attr { sb.write_string('&#10;') } else { sb.write_u8(b) } }
			`\r` { sb.write_string('&#13;') }
			else { sb.write_u8(b) }
		}
	}
}

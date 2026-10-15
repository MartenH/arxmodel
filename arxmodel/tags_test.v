module arxmodel

fn test_tags_pairs_and_values_with_separators() {
	tags, bad := parse_tags('a.b="x";c="1;2";  d="&lt;p&gt;"')
	assert bad.len == 0
	assert tags.len == 3
	assert tags[0] == Tag{'a.b', 'x'}
	assert tags[1] == Tag{'c', '1;2'}
	assert tags[2] == Tag{'d', '<p>'}
}

fn test_tags_malformed_text_is_kept() {
	tags, bad := parse_tags('a="1";nonsense;b="2";c=3;d="open')
	assert tags.map(it.key) == ['a', 'b']
	assert bad == ['nonsense', 'c=3', 'd="open']
}

fn test_stereotypes() {
	assert parse_stereotypes('atpSplitable, atpObject,,') == ['atpSplitable', 'atpObject']
}

fn test_occurs() {
	assert occurs('-1')? == unbounded
	assert occurs(' 3 ')? == 3
	assert occurs('x') == none
	assert occurs('') == none
}

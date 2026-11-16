package nostr

import "core:encoding/json"
import "core:strings"

Tag_Filter :: struct {
	name:   string, // single letter
	values: []string,
}

// A subscription filter (NIP-01). `has_*` tells whether a list was given
// (an empty list matches nothing).
Filter :: struct {
	ids:         []string,
	has_ids:     bool,
	authors:     []string,
	has_authors: bool,
	kinds:       []i64,
	has_kinds:   bool,
	tags:        []Tag_Filter,
	since:       Maybe(i64),
	until:       Maybe(i64),
	limit:       Maybe(i64),
}

// Decode a filter object. Every string is copied with `allocator`, so the
// filter outlives the parsed message.
filter_from_json :: proc(v: json.Value, allocator := context.allocator) -> (f: Filter, err: string) {
	obj, is_obj := v.(json.Object)
	if !is_obj {return f, "filter must be an object"}
	tags := make([dynamic]Tag_Filter, allocator)
	for key, value in obj {
		switch key {
		case "ids":
			f.ids, err = strings_from_json(value, allocator)
			if err != "" {return}
			f.has_ids = true
		case "authors":
			f.authors, err = strings_from_json(value, allocator)
			if err != "" {return}
			f.has_authors = true
		case "kinds":
			arr, ok := value.(json.Array)
			if !ok {return f, "kinds must be an array of integers"}
			kinds := make([]i64, len(arr), allocator)
			for k, i in arr {
				n, is_int := k.(json.Integer)
				if !is_int {return f, "kinds must be an array of integers"}
				kinds[i] = n
			}
			f.kinds = kinds
			f.has_kinds = true
		case "since", "until", "limit":
			n, is_int := value.(json.Integer)
			if !is_int {return f, strings.concatenate({key, " must be an integer"}, allocator)}
			switch key {
			case "since":
				f.since = n
			case "until":
				f.until = n
			case:
				f.limit = n
			}
		case:
			// Only single-letter tags are indexed; ignore everything else.
			if len(key) == 2 && key[0] == '#' {
				values: []string
				values, err = strings_from_json(value, allocator)
				if err != "" {return}
				append(&tags, Tag_Filter{name = strings.clone(key[1:], allocator), values = values})
			}
		}
	}
	f.tags = tags[:]
	return f, ""
}

@(private)
strings_from_json :: proc(v: json.Value, allocator := context.allocator) -> (out: []string, err: string) {
	arr, ok := v.(json.Array)
	if !ok {return nil, "filter lists must be arrays of strings"}
	out = make([]string, len(arr), allocator)
	for item, i in arr {
		s, is_str := item.(json.String)
		if !is_str {return nil, "filter lists must be arrays of strings"}
		out[i] = strings.clone(s, allocator)
	}
	return out, ""
}

@(private)
contains :: proc(values: []$T, has: bool, x: T) -> bool {
	if !has {return true}
	for v in values {
		if v == x {return true}
	}
	return false
}

// Whether an event matches the filter (`limit` is ignored).
filter_matches :: proc(f: Filter, ev: Event) -> bool {
	if !contains(f.ids, f.has_ids, ev.id) {return false}
	if !contains(f.authors, f.has_authors, ev.pubkey) {return false}
	if !contains(f.kinds, f.has_kinds, ev.kind) {return false}
	if since, ok := f.since.?; ok && ev.created_at < since {return false}
	if until, ok := f.until.?; ok && ev.created_at > until {return false}
	for tf in f.tags {
		found := false
		search: for tag in ev.tags {
			if len(tag) >= 2 && tag[0] == tf.name {
				for v in tf.values {
					if v == tag[1] {
						found = true
						break search
					}
				}
			}
		}
		if !found {return false}
	}
	return true
}

filters_match_any :: proc(filters: []Filter, ev: Event) -> bool {
	for f in filters {
		if filter_matches(f, ev) {return true}
	}
	return false
}

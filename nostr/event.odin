package nostr

import "core:crypto/sha2"
import "core:encoding/json"
import "core:strconv"
import "core:strings"

// A Nostr event (NIP-01). Strings point into the parsed message, so an
// event lives as long as the JSON value it came from.
Event :: struct {
	id:         string,
	pubkey:     string,
	created_at: i64,
	kind:       i64,
	tags:       [][]string,
	content:    string,
	sig:        string,
}

Kind_Class :: enum {
	Regular,
	Replaceable,
	Ephemeral,
	Addressable,
}

classify :: proc(kind: i64) -> Kind_Class {
	switch {
	case kind == 0 || kind == 3:
		return .Replaceable
	case kind >= 10_000 && kind < 20_000:
		return .Replaceable
	case kind >= 20_000 && kind < 30_000:
		return .Ephemeral
	case kind >= 30_000 && kind < 40_000:
		return .Addressable
	}
	return .Regular
}

// Decode an event object. Tags are allocated with `allocator`.
event_from_json :: proc(v: json.Value, allocator := context.allocator) -> (ev: Event, ok: bool) {
	obj := v.(json.Object) or_return
	ev.id = obj["id"].(json.String) or_return
	ev.pubkey = obj["pubkey"].(json.String) or_return
	ev.created_at = obj["created_at"].(json.Integer) or_return
	ev.kind = obj["kind"].(json.Integer) or_return
	ev.content = obj["content"].(json.String) or_return
	ev.sig = obj["sig"].(json.String) or_return
	tags := obj["tags"].(json.Array) or_return
	ev.tags = make([][]string, len(tags), allocator)
	for t, i in tags {
		tag := t.(json.Array) or_return
		ev.tags[i] = make([]string, len(tag), allocator)
		for s, j in tag {
			ev.tags[i][j] = s.(json.String) or_return
		}
	}
	return ev, true
}

@(private)
write_tags :: proc(b: ^strings.Builder, tags: [][]string, mode: Escape_Mode) {
	strings.write_byte(b, '[')
	for tag, i in tags {
		if i > 0 {strings.write_byte(b, ',')}
		strings.write_byte(b, '[')
		for s, j in tag {
			if j > 0 {strings.write_byte(b, ',')}
			strings.write_byte(b, '"')
			write_escaped(b, s, mode)
			strings.write_byte(b, '"')
		}
		strings.write_byte(b, ']')
	}
	strings.write_byte(b, ']')
}

// The NIP-01 serialization whose sha256 is the event id.
serialize_for_id :: proc(ev: Event, mode: Escape_Mode, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `[0,"`)
	strings.write_string(&b, ev.pubkey)
	strings.write_string(&b, `",`)
	strings.write_i64(&b, ev.created_at)
	strings.write_byte(&b, ',')
	strings.write_i64(&b, ev.kind)
	strings.write_byte(&b, ',')
	write_tags(&b, ev.tags, mode)
	strings.write_string(&b, `,"`)
	write_escaped(&b, ev.content, mode)
	strings.write_string(&b, `"]`)
	return strings.to_string(b)
}

compute_id :: proc(ev: Event, mode: Escape_Mode) -> (id: [32]u8) {
	s := serialize_for_id(ev, mode)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)s)
	sha2.final(&ctx, id[:])
	return
}

// Whether the id matches the event. Strings with unusual control characters
// are checked against every serialization clients are known to use.
id_matches :: proc(ev: Event, id: [32]u8) -> bool {
	if compute_id(ev, .Nip01) == id {
		return true
	}
	if !has_ambiguous_strings(ev) {
		return false
	}
	return compute_id(ev, .Strict) == id || compute_id(ev, .Minimal) == id
}

@(private)
has_ambiguous_strings :: proc(ev: Event) -> bool {
	if has_ambiguous_control(ev.content) {return true}
	for tag in ev.tags {
		for s in tag {
			if has_ambiguous_control(s) {return true}
		}
	}
	return false
}

// Serialize an event as a JSON object.
event_to_json :: proc(ev: Event, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"id":"`)
	strings.write_string(&b, ev.id)
	strings.write_string(&b, `","pubkey":"`)
	strings.write_string(&b, ev.pubkey)
	strings.write_string(&b, `","created_at":`)
	strings.write_i64(&b, ev.created_at)
	strings.write_string(&b, `,"kind":`)
	strings.write_i64(&b, ev.kind)
	strings.write_string(&b, `,"tags":`)
	write_tags(&b, ev.tags, .Strict)
	strings.write_string(&b, `,"content":`)
	write_quoted(&b, ev.content)
	strings.write_string(&b, `,"sig":"`)
	strings.write_string(&b, ev.sig)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

is_lower_hex :: proc(s: string, n: int) -> bool {
	if len(s) != n {return false}
	for i in 0 ..< len(s) {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {return false}
	}
	return true
}

// Decode lowercase hex that already passed `is_lower_hex`.
@(private)
decode_hex :: proc(s: string, out: []u8) {
	nib :: proc(c: u8) -> u8 {
		return c - '0' if c <= '9' else c - 'a' + 10
	}
	for i in 0 ..< len(out) {
		out[i] = nib(s[2 * i]) << 4 | nib(s[2 * i + 1])
	}
}

// Check the shape of the event, its id and its signature.
// The error message is suitable for an `OK` response.
validate :: proc(ev: Event) -> (err: string, ok: bool) {
	if !is_lower_hex(ev.id, 64) {return "invalid: bad event id format", false}
	if !is_lower_hex(ev.pubkey, 64) {return "invalid: bad pubkey format", false}
	if !is_lower_hex(ev.sig, 128) {return "invalid: bad signature format", false}
	if ev.kind < 0 || ev.kind > 65_535 {return "invalid: kind out of range", false}
	if ev.created_at < 0 {return "invalid: bad created_at", false}
	id: [32]u8
	pubkey: [32]u8
	sig: [64]u8
	decode_hex(ev.id, id[:])
	decode_hex(ev.pubkey, pubkey[:])
	decode_hex(ev.sig, sig[:])
	if !id_matches(ev, id) {return "invalid: event id does not match", false}
	if !schnorr_verify(pubkey, id[:], sig) {
		return "invalid: signature verification failed", false
	}
	return "", true
}

// The first value of the first tag with the given name.
tag_value :: proc(ev: Event, name: string) -> (string, bool) {
	for tag in ev.tags {
		if len(tag) >= 2 && tag[0] == name {return tag[1], true}
	}
	return "", false
}

has_tag :: proc(ev: Event, name: string) -> bool {
	for tag in ev.tags {
		if len(tag) >= 1 && tag[0] == name {return true}
	}
	return false
}

// The `d` tag value used to identify addressable events ("" if missing).
d_tag :: proc(ev: Event) -> string {
	v, _ := tag_value(ev, "d")
	return v
}

// NIP-40 expiration timestamp.
expiration :: proc(ev: Event) -> (exp: i64, ok: bool) {
	v := tag_value(ev, "expiration") or_return
	return strconv.parse_i64_of_base(v, 10)
}

is_expired :: proc(ev: Event, now: i64) -> bool {
	exp, ok := expiration(ev)
	return ok && exp <= now
}

// `name:value` entries for every single-letter tag, used for tag filters.
tag_index :: proc(ev: Event, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(ev.tags), allocator)
	outer: for tag in ev.tags {
		if len(tag) < 2 || len(tag[0]) != 1 {continue}
		entry := strings.concatenate({tag[0], ":", tag[1]}, allocator)
		for e in out {
			if e == entry {continue outer}
		}
		append(&out, entry)
	}
	return out[:]
}

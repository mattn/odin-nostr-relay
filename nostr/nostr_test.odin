package nostr

import "core:encoding/json"
import "core:strings"
import "core:testing"

// Generated with nak (secret key 0x...03).
EVENT_WITH_ESCAPES :: `{"kind":1,"id":"fb1888e17a1e8a11e7bd30ca2696736f69b004900e1b8e186b67f0687f74f916","pubkey":"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9","created_at":1700000000,"tags":[["e","aaaa"],["p","bbbb"],["t","gleam"]],"content":"hi \"there\"\\\n\ttab\u0008\u000c\r日本語 \u0001 end","sig":"f1a8c9d5e1afcde99f206a5ebee3f3600b95a3a8d0a8c86c2290d99b481bd77ff755a801669273bbee45a6d6f13827e221cfb29122b9a641f0ad83cdb3f2d646"}`

EVENT_PLAIN :: `{"kind":1,"id":"8e39f6f58eaa259d9139c9af21822f9e214e0d3315a996d3271724a04f64bbb6","pubkey":"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9","created_at":1700000000,"tags":[],"content":"plain\nline","sig":"25a7a983cfc38abe86c85aaf2c849c395c9d98dfe16b83114c2b8d43dfed86aca95d42ef84666ac051a7027ceeb7c7aa62b36f29ef8b4581a0c9806dee9b5c31"}`

@(private = "file")
parse_value :: proc(t: ^testing.T, s: string) -> json.Value {
	v, err := json.parse_string(s, .JSON, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	return v
}

@(private = "file")
parse_event :: proc(t: ^testing.T, s: string) -> Event {
	ev, ok := event_from_json(parse_value(t, s), context.temp_allocator)
	testing.expect(t, ok)
	return ev
}

@(private = "file")
parse_filter :: proc(t: ^testing.T, s: string) -> Filter {
	f, err := filter_from_json(parse_value(t, s), context.temp_allocator)
	testing.expect_value(t, err, "")
	return f
}

@(private = "file")
hex32 :: proc(s: string) -> (out: [32]u8) {
	decode_hex(s, out[:])
	return
}

@(test)
test_event_with_escapes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ev := parse_event(t, EVENT_WITH_ESCAPES)
	id := hex32(ev.id)
	// nak (current go-nostr) leaves \b, \f and \u0001 unescaped.
	testing.expect(t, compute_id(ev, .Minimal) == id)
	testing.expect(t, compute_id(ev, .Nip01) != id)
	err, ok := validate(ev)
	testing.expectf(t, ok, "validate: %s", err)
}

@(test)
test_plain_event :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, ok := validate(parse_event(t, EVENT_PLAIN))
	testing.expect(t, ok)
}

@(test)
test_tampered :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ev := parse_event(t, EVENT_PLAIN)
	bad := ev
	bad.content = "tampered"
	err, _ := validate(bad)
	testing.expect_value(t, err, "invalid: event id does not match")

	bad = ev
	bad.sig = strings.concatenate({ev.sig[:126], "00"}, context.temp_allocator)
	err, _ = validate(bad)
	testing.expect_value(t, err, "invalid: signature verification failed")

	bad = ev
	bad.id = strings.to_upper(ev.id, context.temp_allocator)
	err, _ = validate(bad)
	testing.expect_value(t, err, "invalid: bad event id format")
}

@(test)
test_to_json_roundtrip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ev := parse_event(t, EVENT_WITH_ESCAPES)
	again := parse_event(t, event_to_json(ev))
	testing.expect_value(t, again.content, ev.content)
	testing.expect_value(t, again.id, ev.id)
	testing.expect_value(t, len(again.tags), 3)
	testing.expect_value(t, again.tags[2][1], "gleam")
}

@(test)
test_escape_modes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	esc :: proc(s: string, mode: Escape_Mode) -> string {
		b := strings.builder_make(context.temp_allocator)
		write_escaped(&b, s, mode)
		return strings.to_string(b)
	}
	s := "a\"b\\c\nd\te\x08f\x01"
	testing.expect_value(t, esc(s, .Nip01), "a\\\"b\\\\c\\nd\\te\\bf\x01")
	testing.expect_value(t, esc(s, .Strict), "a\\\"b\\\\c\\nd\\te\\bf\\u0001")
	testing.expect_value(t, esc(s, .Minimal), "a\\\"b\\\\c\\nd\\te\x08f\x01")
	testing.expect_value(t, esc("日本語", .Strict), "日本語")
}

@(test)
test_classify :: proc(t: ^testing.T) {
	testing.expect_value(t, classify(0), Kind_Class.Replaceable)
	testing.expect_value(t, classify(1), Kind_Class.Regular)
	testing.expect_value(t, classify(3), Kind_Class.Replaceable)
	testing.expect_value(t, classify(10_002), Kind_Class.Replaceable)
	testing.expect_value(t, classify(20_001), Kind_Class.Ephemeral)
	testing.expect_value(t, classify(30_023), Kind_Class.Addressable)
	testing.expect_value(t, classify(40_000), Kind_Class.Regular)
}

@(test)
test_tag_index :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	idx := tag_index(parse_event(t, EVENT_WITH_ESCAPES))
	testing.expect_value(t, len(idx), 3)
	testing.expect_value(t, idx[0], "e:aaaa")
	testing.expect_value(t, idx[1], "p:bbbb")
	testing.expect_value(t, idx[2], "t:gleam")
}

@(test)
test_filter_decode :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := parse_filter(t, `{"kinds":[1],"#t":["odin"],"limit":5,"#long":["x"]}`)
	testing.expect(t, f.has_kinds && len(f.kinds) == 1 && f.kinds[0] == 1)
	testing.expect_value(t, f.limit.? or_else -1, 5)
	testing.expect_value(t, len(f.tags), 1)
	testing.expect_value(t, f.tags[0].name, "t")
	testing.expect_value(t, f.tags[0].values[0], "odin")
	_, err := filter_from_json(parse_value(t, `{"kinds":["x"]}`), context.temp_allocator)
	testing.expect_value(t, err, "kinds must be an array of integers")
	_, err = filter_from_json(parse_value(t, `{"since":1.5}`), context.temp_allocator)
	testing.expect_value(t, err, "since must be an integer")
}

@(test)
test_filter_match :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ev := parse_event(t, EVENT_WITH_ESCAPES)
	testing.expect(t, filter_matches(parse_filter(t, `{}`), ev))
	testing.expect(t, filter_matches(parse_filter(t, `{"kinds":[1,2],"#e":["aaaa"]}`), ev))
	testing.expect(
		t,
		filter_matches(parse_filter(t, strings.concatenate({`{"authors":["`, ev.pubkey, `"]}`}, context.temp_allocator)), ev),
	)
	testing.expect(t, !filter_matches(parse_filter(t, `{"kinds":[2]}`), ev))
	testing.expect(t, !filter_matches(parse_filter(t, `{"#e":["bbbb"]}`), ev))
	testing.expect(t, !filter_matches(parse_filter(t, `{"ids":[]}`), ev))
	testing.expect(t, filter_matches(parse_filter(t, `{"since":1700000000,"until":1700000000}`), ev))
	testing.expect(t, !filter_matches(parse_filter(t, `{"since":1700000001}`), ev))
}

@(test)
test_expiration :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ev := parse_event(t, EVENT_PLAIN)
	ev.tags = {{"expiration", "100"}}
	testing.expect(t, is_expired(ev, 100))
	testing.expect(t, !is_expired(ev, 99))
}

// A few BIP-340 vectors; libsecp256k1 is tested upstream, this checks the
// binding.
@(test)
test_schnorr_vectors :: proc(t: ^testing.T) {
	Vector :: struct {
		pubkey, msg, sig: string,
		ok:               bool,
	}
	vectors := []Vector {
		{"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9", "0000000000000000000000000000000000000000000000000000000000000000", "e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0", true},
		{"dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659", "243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89", "6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de33418906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a", true},
		{"eefdea4cdb677750a420fee807eacf21eb9898ae79b9768766e4faa04a2d4a34", "243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89", "6cff5c3ba86c69ea4b7376f31a9bcb4f74c1976089b2d9963da2e5543e17776969e89b4c5564d00349106b8497785dd7d1d713a8ae82b32fa79d5f7fc407d39b", false},
		{"dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659", "243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89", "fff97bd5755eeea420453a14355235d382f6472f8568a18b2f057a14602975563cc27944640ac607cd107ae10923d9ef7a73c643e166be5ebeafa34b1ac553e2", false},
	}
	for v in vectors {
		pk := hex32(v.pubkey)
		msg := hex32(v.msg)
		sig: [64]u8
		decode_hex(v.sig, sig[:])
		testing.expect_value(t, schnorr_verify(pk, msg[:], sig), v.ok)
	}
}

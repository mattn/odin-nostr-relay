package nostr

import "core:strings"

// How control characters are escaped.
//
// Clients disagree on the serialization used for event ids when strings
// contain control characters other than `\n`, `\r` and `\t`, so the relay
// accepts any of these.
Escape_Mode :: enum {
	// NIP-01 as written: `\b` and `\f` are escaped, other control characters
	// are written as-is.
	Nip01,
	// `JSON.stringify` (nostr-tools) and older go-nostr: `\b`, `\f`, and
	// `\u00XX` for other control characters. Always valid JSON.
	Strict,
	// Current go-nostr (and nak): only `"`, `\`, `\n`, `\r` and `\t` are
	// escaped.
	Minimal,
}

HEX_DIGITS := "0123456789abcdef"

// Write `s` to `b` escaped for use inside a JSON string literal.
write_escaped :: proc(b: ^strings.Builder, s: string, mode: Escape_Mode) {
	start := 0
	for i in 0 ..< len(s) {
		c := s[i]
		seq: string
		switch c {
		case '"':
			seq = `\"`
		case '\\':
			seq = `\\`
		case '\n':
			seq = `\n`
		case '\r':
			seq = `\r`
		case '\t':
			seq = `\t`
		case 0x08:
			if mode != .Minimal {seq = `\b`}
		case 0x0c:
			if mode != .Minimal {seq = `\f`}
		}
		if seq == "" && c < 0x20 && mode == .Strict {
			strings.write_string(b, s[start:i])
			strings.write_string(b, `\u00`)
			strings.write_byte(b, HEX_DIGITS[c >> 4])
			strings.write_byte(b, HEX_DIGITS[c & 0xf])
			start = i + 1
			continue
		}
		if seq != "" {
			strings.write_string(b, s[start:i])
			strings.write_string(b, seq)
			start = i + 1
		}
	}
	strings.write_string(b, s[start:])
}

// Write `s` to `b` as a quoted JSON string (always valid JSON).
write_quoted :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	write_escaped(b, s, .Strict)
	strings.write_byte(b, '"')
}

// Whether the string contains control characters on which the escaping
// modes disagree.
has_ambiguous_control :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		c := s[i]
		if c < 0x20 && c != '\t' && c != '\n' && c != '\r' {
			return true
		}
	}
	return false
}

package main

import "core:os"
import "core:strconv"
import "core:strings"
import "../nostr"

VERSION :: "0.1.0"

SUPPORTED_NIPS :: [?]int{1, 9, 11, 40, 45, 70}

MAX_MESSAGE_LENGTH :: 524_288
MAX_SUBSCRIPTIONS :: 20
MAX_FILTERS :: 10
MAX_LIMIT :: 500
DEFAULT_LIMIT :: 500
MAX_EVENT_TAGS :: 2000
MAX_CONTENT_LENGTH :: 102_400
// Events with created_at further in the future than this are rejected.
CREATED_AT_UPPER_LIMIT :: 900
MAX_SUBSCRIPTION_ID_LENGTH :: 64

Config :: struct {
	port:         int,
	database_url: string,
	web_root:     string,
	name:         string,
	description:  string,
	pubkey:       string,
	contact:      string,
	icon:         string,
}

config: Config

@(private = "file")
env :: proc(name, default: string) -> string {
	v := os.get_env(name, context.allocator)
	return v if v != "" else default
}

config_from_env :: proc() -> Config {
	port, ok := strconv.parse_int(env("PORT", "8080"))
	return Config {
		port = port if ok else 8080,
		database_url = env("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/nostr"),
		web_root = env("WEB_ROOT", "public"),
		name = env("RELAY_NAME", "odin-nostr-relay"),
		description = env("RELAY_DESCRIPTION", "A Nostr relay implemented in Odin"),
		pubkey = env("RELAY_PUBKEY", ""),
		contact = env("RELAY_CONTACT", ""),
		icon = env("RELAY_ICON", ""),
	}
}

// NIP-11 relay information document.
nip11_json :: proc(cfg: Config, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	field :: proc(b: ^strings.Builder, key, value: string) {
		strings.write_byte(b, '"')
		strings.write_string(b, key)
		strings.write_string(b, `":`)
		nostr.write_quoted(b, value)
		strings.write_byte(b, ',')
	}
	strings.write_byte(&b, '{')
	field(&b, "name", cfg.name)
	field(&b, "description", cfg.description)
	if cfg.pubkey != "" {field(&b, "pubkey", cfg.pubkey)}
	if cfg.contact != "" {field(&b, "contact", cfg.contact)}
	if cfg.icon != "" {field(&b, "icon", cfg.icon)}
	field(&b, "software", "https://github.com/mattn/odin-nostr-relay")
	field(&b, "version", VERSION)
	strings.write_string(&b, `"supported_nips":[`)
	for nip, i in SUPPORTED_NIPS {
		if i > 0 {strings.write_byte(&b, ',')}
		strings.write_int(&b, nip)
	}
	strings.write_string(&b, `],"limitation":{`)
	limits := [?]struct {
		key:   string,
		value: int,
	} {
		{"max_message_length", MAX_MESSAGE_LENGTH},
		{"max_subscriptions", MAX_SUBSCRIPTIONS},
		{"max_filters", MAX_FILTERS},
		{"max_limit", MAX_LIMIT},
		{"max_subid_length", MAX_SUBSCRIPTION_ID_LENGTH},
		{"default_limit", DEFAULT_LIMIT},
		{"max_event_tags", MAX_EVENT_TAGS},
		{"max_content_length", MAX_CONTENT_LENGTH},
		{"created_at_upper_limit", CREATED_AT_UPPER_LIMIT},
	}
	for l in limits {
		strings.write_byte(&b, '"')
		strings.write_string(&b, l.key)
		strings.write_string(&b, `":`)
		strings.write_int(&b, l.value)
		strings.write_byte(&b, ',')
	}
	strings.write_string(&b, `"auth_required":false,"payment_required":false}}`)
	return strings.to_string(b)
}

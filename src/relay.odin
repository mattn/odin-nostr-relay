package main

import "core:encoding/json"
import "core:mem/virtual"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import "../nostr"

// Nostr protocol handling (NIP-01, NIP-09, NIP-40, NIP-45, NIP-70).

Subscription :: struct {
	// Owns the id and the filters.
	arena:   virtual.Arena,
	id:      string,
	filters: []nostr.Filter,
}

Client :: struct {
	sock:   net.TCP_Socket,
	// Guards writes to the socket and `subs`. Only the connection thread
	// changes `subs`; broadcasting threads read it.
	mu:     sync.Mutex,
	subs:   map[string]^Subscription,
	closed: bool,
}

@(private = "file")
clients_mu: sync.RW_Mutex
@(private = "file")
clients: map[^Client]struct {}

now :: proc() -> i64 {
	return time.time_to_unix(time.now())
}

client_register :: proc(sock: net.TCP_Socket) -> ^Client {
	c := new(Client)
	c.sock = sock
	sync.rw_mutex_lock(&clients_mu)
	clients[c] = {}
	sync.rw_mutex_unlock(&clients_mu)
	return c
}

client_unregister :: proc(c: ^Client) {
	sync.rw_mutex_lock(&clients_mu)
	delete_key(&clients, c)
	sync.rw_mutex_unlock(&clients_mu)
	// No broadcaster can see the client any more.
	for _, sub in c.subs {
		subscription_free(sub)
	}
	delete(c.subs)
	free(c)
}

@(private = "file")
subscription_free :: proc(sub: ^Subscription) {
	virtual.arena_destroy(&sub.arena)
	free(sub)
}

// Write a frame; the caller holds `c.mu`.
@(private = "file")
write_locked :: proc(c: ^Client, opcode: Opcode, payload: []u8) {
	if c.closed {return}
	if !ws_write(c.sock, opcode, payload) || opcode == .Close {
		// Unblock the reader so the connection thread exits.
		c.closed = true
		net.shutdown(c.sock, .Both)
	}
}

client_write :: proc(c: ^Client, opcode: Opcode, payload: []u8) {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	write_locked(c, opcode, payload)
}

client_send :: proc(c: ^Client, text: string) {
	client_write(c, .Text, transmute([]u8)text)
}

client_is_closed :: proc(c: ^Client) -> bool {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	return c.closed
}

// Deliver a newly accepted event to every matching live subscription.
@(private = "file")
broadcast :: proc(ev: nostr.Event) {
	raw := nostr.event_to_json(ev)
	sync.rw_mutex_shared_lock(&clients_mu)
	defer sync.rw_mutex_shared_unlock(&clients_mu)
	for c in clients {
		sync.mutex_lock(&c.mu)
		for id, sub in c.subs {
			if nostr.filters_match_any(sub.filters, ev) {
				msg := event_msg(id, raw)
				write_locked(c, .Text, transmute([]u8)msg)
			}
		}
		sync.mutex_unlock(&c.mu)
	}
}

notice :: proc(msg: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `["NOTICE",`)
	nostr.write_quoted(&b, msg)
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

@(private = "file")
ok_msg :: proc(id: string, accepted: bool, msg: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `["OK",`)
	nostr.write_quoted(&b, id)
	strings.write_string(&b, ",true," if accepted else ",false,")
	nostr.write_quoted(&b, msg)
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

@(private = "file")
closed_msg :: proc(sub_id: string, msg: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `["CLOSED",`)
	nostr.write_quoted(&b, sub_id)
	strings.write_byte(&b, ',')
	nostr.write_quoted(&b, msg)
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

@(private = "file")
event_msg :: proc(sub_id: string, raw: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `["EVENT",`)
	nostr.write_quoted(&b, sub_id)
	strings.write_byte(&b, ',')
	strings.write_string(&b, raw)
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

MAX_JSON_DEPTH :: 16

// The JSON parser is recursive, so reject deeply nested input before
// parsing it to keep a hostile message from exhausting the stack.
@(private = "file")
too_deep :: proc(s: string) -> bool {
	depth := 0
	in_string := false
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if in_string {
			if c == '\\' {
				i += 1
			} else if c == '"' {
				in_string = false
			}
			continue
		}
		switch c {
		case '"':
			in_string = true
		case '[', '{':
			depth += 1
			if depth > MAX_JSON_DEPTH {return true}
		case ']', '}':
			depth -= 1
		}
	}
	return false
}

// Handle one complete text message. Everything allocated here is temporary.
handle_message :: proc(c: ^Client, text: string) {
	if len(text) > MAX_MESSAGE_LENGTH {
		client_send(c, notice("error: message too large"))
		return
	}
	if !utf8.valid_string(text) {
		client_send(c, notice("error: message is not valid UTF-8"))
		return
	}
	if too_deep(text) {
		client_send(c, notice("error: message is nested too deeply"))
		return
	}
	value, err := json.parse_string(text, .JSON, true, context.temp_allocator)
	arr, is_arr := value.(json.Array)
	if err != nil || !is_arr {
		client_send(c, notice("error: invalid message, expected a JSON array"))
		return
	}
	if len(arr) == 0 {
		client_send(c, notice("error: empty message"))
		return
	}
	cmd, is_str := arr[0].(json.String)
	if !is_str {
		client_send(c, notice("error: invalid command"))
		return
	}
	args := arr[1:]
	switch {
	case cmd == "EVENT" && len(args) == 1:
		handle_event(c, args[0])
	case cmd == "REQ" && len(args) >= 1:
		if id, ok := sub_id(c, args[0]); ok {handle_req(c, id, args[1:])}
	case cmd == "COUNT" && len(args) >= 1:
		if id, ok := sub_id(c, args[0]); ok {handle_count(c, id, args[1:])}
	case cmd == "CLOSE" && len(args) == 1:
		if id, ok := sub_id(c, args[0]); ok {remove_subscription(c, id)}
	case:
		client_send(
			c,
			notice(strings.concatenate({"error: unknown or malformed command: ", cmd}, context.temp_allocator)),
		)
	}
}

@(private = "file")
sub_id :: proc(c: ^Client, v: json.Value) -> (string, bool) {
	id, ok := v.(json.String)
	if !ok {
		client_send(c, notice("error: subscription id must be a string"))
		return "", false
	}
	if id == "" || len(id) > MAX_SUBSCRIPTION_ID_LENGTH {
		client_send(c, closed_msg(id, "error: invalid subscription id"))
		return "", false
	}
	return id, true
}

@(private = "file")
remove_subscription :: proc(c: ^Client, id: string) {
	sync.mutex_lock(&c.mu)
	sub, found := c.subs[id]
	if found {delete_key(&c.subs, id)}
	sync.mutex_unlock(&c.mu)
	if found {subscription_free(sub)}
}

// Parse the filters of a REQ or COUNT with `allocator`.
@(private = "file")
parse_filters :: proc(values: []json.Value, allocator := context.temp_allocator) -> (filters: []nostr.Filter, err: string) {
	if len(values) == 0 {return nil, "error: at least one filter is required"}
	if len(values) > MAX_FILTERS {return nil, "error: too many filters"}
	filters = make([]nostr.Filter, len(values), allocator)
	for v, i in values {
		f, e := nostr.filter_from_json(v, allocator)
		if e != "" {
			return nil, strings.concatenate({"error: ", e}, context.temp_allocator)
		}
		filters[i] = f
	}
	return filters, ""
}

@(private = "file")
handle_req :: proc(c: ^Client, id: string, values: []json.Value) {
	_, exists := c.subs[id]
	if !exists && len(c.subs) >= MAX_SUBSCRIPTIONS {
		client_send(c, closed_msg(id, "error: too many subscriptions"))
		return
	}
	sub := new(Subscription)
	if virtual.arena_init_growing(&sub.arena, 16 * 1024) != nil {
		free(sub)
		client_send(c, closed_msg(id, "error: out of memory"))
		return
	}
	alloc := virtual.arena_allocator(&sub.arena)
	filters, err := parse_filters(values, alloc)
	if err != "" {
		subscription_free(sub)
		remove_subscription(c, id)
		client_send(c, closed_msg(id, err))
		return
	}
	sub.id = strings.clone(id, alloc)
	sub.filters = filters

	ts := now()
	seen := make(map[string]struct {}, context.temp_allocator)
	for f in filters {
		limit := clamp(f.limit.? or_else DEFAULT_LIMIT, 0, MAX_LIMIT)
		if limit == 0 {continue}
		rows, db_err := db_query(f, ts, limit)
		if msg, failed := db_err.?; failed {
			subscription_free(sub)
			remove_subscription(c, id)
			client_send(c, closed_msg(id, msg))
			return
		}
		for raw in rows {
			if raw in seen {continue}
			seen[raw] = {}
			client_send(c, event_msg(id, raw))
		}
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `["EOSE",`)
	nostr.write_quoted(&b, id)
	strings.write_byte(&b, ']')
	client_send(c, strings.to_string(b))

	sync.mutex_lock(&c.mu)
	old, replaced := c.subs[id]
	if replaced {delete_key(&c.subs, id)}
	c.subs[sub.id] = sub
	sync.mutex_unlock(&c.mu)
	if replaced {subscription_free(old)}
}

@(private = "file")
handle_count :: proc(c: ^Client, id: string, values: []json.Value) {
	filters, err := parse_filters(values)
	if err != "" {
		client_send(c, closed_msg(id, err))
		return
	}
	n, db_err := db_count(filters, now())
	if msg, failed := db_err.?; failed {
		client_send(c, closed_msg(id, msg))
		return
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `["COUNT",`)
	nostr.write_quoted(&b, id)
	strings.write_string(&b, `,{"count":`)
	strings.write_int(&b, n)
	strings.write_string(&b, "}]")
	client_send(c, strings.to_string(b))
}

@(private = "file")
handle_event :: proc(c: ^Client, v: json.Value) {
	ev, ok := nostr.event_from_json(v, context.temp_allocator)
	if !ok {
		id := ""
		if obj, is_obj := v.(json.Object); is_obj {
			id = obj["id"].(json.String) or_else ""
		}
		client_send(c, ok_msg(id, false, "invalid: malformed event"))
		return
	}
	msg, accepted := accept(ev)
	client_send(c, ok_msg(ev.id, accepted, msg))
}

@(private = "file")
has_nul :: proc(ev: nostr.Event) -> bool {
	for tag in ev.tags {
		for s in tag {
			if strings.contains_rune(s, 0) {return true}
		}
	}
	return false
}

@(private = "file")
accept :: proc(ev: nostr.Event) -> (msg: string, accepted: bool) {
	ts := now()
	if len(ev.tags) > MAX_EVENT_TAGS {return "invalid: too many tags", false}
	if len(ev.content) > MAX_CONTENT_LENGTH {return "invalid: content too long", false}
	if ev.created_at > ts + CREATED_AT_UPPER_LIMIT {
		return "invalid: created_at is too far in the future", false
	}
	if err, valid := nostr.validate(ev); !valid {return err, false}
	if nostr.is_expired(ev, ts) {return "invalid: event has expired", false}
	// NIP-70: without NIP-42 auth we cannot tell who is publishing.
	if nostr.has_tag(ev, "-") {
		return "auth-required: protected events are not accepted by this relay", false
	}

	if nostr.classify(ev.kind) == .Ephemeral {
		broadcast(ev)
		return "", true
	}
	// PostgreSQL text cannot hold NUL, and tags are stored in columns.
	if has_nul(ev) {return "invalid: tags must not contain NUL characters", false}
	result, err := db_save(ev)
	if e, failed := err.?; failed {return e, false}
	switch result {
	case .Saved:
		if ev.kind == 5 {
			if e, failed := db_apply_deletion(ev).?; failed {return e, false}
		}
		broadcast(ev)
		return "", true
	case .Duplicate:
		return "duplicate: already have this event", true
	case .Have_Newer:
		return "duplicate: have a newer event", false
	case .Already_Deleted:
		return "blocked: event was deleted by its author", false
	}
	return "", false
}

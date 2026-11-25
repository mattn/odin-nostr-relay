package main

import "core:c"
import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:sync"
import "../nostr"

// PostgreSQL event storage through a small pool of libpq connections.

// A database error message, suitable for an `OK` or `CLOSED` response.
Db_Error :: Maybe(string)

Save_Result :: enum {
	Saved,
	Duplicate,
	// A newer version of a replaceable/addressable event is already stored.
	Have_Newer,
	// The event was deleted by its author (NIP-09).
	Already_Deleted,
}

@(private = "file")
Pool :: struct {
	mu:   sync.Mutex,
	cond: sync.Cond,
	free: [dynamic]^PGconn,
}

@(private = "file")
pool: Pool

POOL_SIZE :: 10

// Open the connection pool. libpq understands postgres:// URLs, including
// percent-encoded credentials and `sslmode`.
db_open :: proc(url: string) -> (err: string) {
	curl := strings.clone_to_cstring(url, context.temp_allocator)
	for _ in 0 ..< POOL_SIZE {
		conn := PQconnectdb(curl)
		if PQstatus(conn) != .CONNECTION_OK {
			err = strings.clone(string(PQerrorMessage(conn)))
			PQfinish(conn)
			db_close()
			return strings.trim_space(err)
		}
		append(&pool.free, conn)
	}
	return ""
}

db_close :: proc() {
	sync.mutex_lock(&pool.mu)
	defer sync.mutex_unlock(&pool.mu)
	for conn in pool.free {
		PQfinish(conn)
	}
	clear(&pool.free)
}

@(private = "file")
acquire :: proc() -> ^PGconn {
	sync.mutex_lock(&pool.mu)
	for len(pool.free) == 0 {
		sync.cond_wait(&pool.cond, &pool.mu)
	}
	conn := pop(&pool.free)
	sync.mutex_unlock(&pool.mu)
	if PQstatus(conn) != .CONNECTION_OK {
		log.warn("database connection lost, reconnecting")
		PQreset(conn)
	}
	return conn
}

@(private = "file")
release :: proc(conn: ^PGconn) {
	sync.mutex_lock(&pool.mu)
	append(&pool.free, conn)
	sync.mutex_unlock(&pool.mu)
	sync.cond_signal(&pool.cond)
}

// Query parameters, sent in text format. All memory is temporary.
@(private = "file")
Params :: struct {
	values: [dynamic]cstring,
}

@(private = "file")
params_make :: proc() -> Params {
	return Params{values = make([dynamic]cstring, context.temp_allocator)}
}

// Add a parameter and return its placeholder (`$n`).
@(private = "file")
add :: proc(p: ^Params, v: Maybe(string)) -> string {
	s, ok := v.?
	append(&p.values, strings.clone_to_cstring(s, context.temp_allocator) if ok else nil)
	return fmt.tprintf("$%d", len(p.values))
}

@(private = "file")
add_int :: proc(p: ^Params, n: i64) -> string {
	return add(p, fmt.tprintf("%d", n))
}

// A PostgreSQL array literal of text values.
@(private = "file")
text_array :: proc(values: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	for v, i in values {
		if i > 0 {strings.write_byte(&b, ',')}
		strings.write_byte(&b, '"')
		for j in 0 ..< len(v) {
			if v[j] == '"' || v[j] == '\\' {strings.write_byte(&b, '\\')}
			strings.write_byte(&b, v[j])
		}
		strings.write_byte(&b, '"')
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private = "file")
int_array :: proc(values: []i64) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	for v, i in values {
		if i > 0 {strings.write_byte(&b, ',')}
		strings.write_i64(&b, v)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private = "file")
Rows :: struct {
	rows:     [][]string,
	affected: int,
}

// Run a statement. Returned strings are copied to the temp allocator.
@(private = "file")
exec :: proc(conn: ^PGconn, sql: string, params: []cstring = nil) -> (out: Rows, err: Db_Error) {
	res := PQexecParams(
		conn,
		strings.clone_to_cstring(sql, context.temp_allocator),
		c.int(len(params)),
		nil,
		raw_data(params),
		nil,
		nil,
		0,
	)
	defer PQclear(res)
	status := PQresultStatus(res)
	if status != .PGRES_COMMAND_OK && status != .PGRES_TUPLES_OK {
		msg := res != nil ? string(PQresultErrorMessage(res)) : string(PQerrorMessage(conn))
		return out, strings.concatenate(
			{"error: database error: ", strings.trim_space(msg)},
			context.temp_allocator,
		)
	}
	n := int(PQntuples(res))
	out.rows = make([][]string, n, context.temp_allocator)
	for i in 0 ..< n {
		// Every query here selects a single column.
		row := make([]string, 1, context.temp_allocator)
		v := PQgetvalue(res, c.int(i), 0)
		row[0] = strings.clone(string(v[:PQgetlength(res, c.int(i), 0)]), context.temp_allocator)
		out.rows[i] = row
	}
	out.affected, _ = strconv.parse_int(string(PQcmdTuples(res)))
	return out, nil
}

@(private = "file")
first_int :: proc(r: Rows) -> int {
	if len(r.rows) == 0 {return 0}
	n, _ := strconv.parse_int(r.rows[0][0])
	return n
}

@(private = "file")
SCHEMA := [?]string {
	`CREATE TABLE IF NOT EXISTS event (
		id text PRIMARY KEY,
		pubkey text NOT NULL,
		created_at bigint NOT NULL,
		kind integer NOT NULL,
		tagvalues text[] NOT NULL,
		d_tag text,
		expiration bigint,
		raw text NOT NULL
	)`,
	"CREATE INDEX IF NOT EXISTS event_pubkey_idx ON event (pubkey)",
	"CREATE INDEX IF NOT EXISTS event_created_at_idx ON event (created_at DESC)",
	"CREATE INDEX IF NOT EXISTS event_kind_idx ON event (kind)",
	"CREATE INDEX IF NOT EXISTS event_replace_idx ON event (pubkey, kind, d_tag)",
	"CREATE INDEX IF NOT EXISTS event_tagvalues_idx ON event USING gin (tagvalues)",
	"CREATE INDEX IF NOT EXISTS event_expiration_idx ON event (expiration) WHERE expiration IS NOT NULL",
}

db_migrate :: proc() -> (err: Db_Error) {
	conn := acquire()
	defer release(conn)
	for sql in SCHEMA {
		exec(conn, sql) or_return
	}
	return nil
}

// Store an event, handling replaceable/addressable semantics and NIP-09
// deletions. Ephemeral events must not be passed here.
db_save :: proc(ev: nostr.Event) -> (result: Save_Result, err: Db_Error) {
	conn := acquire()
	defer release(conn)
	exec(conn, "BEGIN") or_return
	result, err = save_tx(conn, ev)
	if err != nil {
		exec(conn, "ROLLBACK")
		return
	}
	_, err = exec(conn, "COMMIT")
	return
}

@(private = "file")
save_tx :: proc(conn: ^PGconn, ev: nostr.Event) -> (result: Save_Result, err: Db_Error) {
	p := params_make()
	sql := fmt.tprintf(
		"SELECT count(*) FROM event WHERE kind = 5 AND pubkey = %s AND tagvalues && %s::text[]",
		add(&p, ev.pubkey),
		add(&p, text_array({strings.concatenate({"e:", ev.id}, context.temp_allocator)})),
	)
	if first_int(exec(conn, sql, p.values[:]) or_return) != 0 {
		return .Already_Deleted, nil
	}

	class := nostr.classify(ev.kind)
	d: Maybe(string)
	if class == .Addressable {d = nostr.d_tag(ev)}
	if class == .Replaceable || class == .Addressable {
		dv := d.? or_else ""
		// Serialize writers of the same replaceable slot.
		p = params_make()
		slot := fmt.tprintf("%s:%d:%s", ev.pubkey, ev.kind, dv)
		exec(conn, fmt.tprintf("SELECT 1 FROM (SELECT pg_advisory_xact_lock(hashtext(%s))) s", add(&p, slot)), p.values[:]) or_return

		p = params_make()
		pk, kind, dd := add(&p, ev.pubkey), add_int(&p, ev.kind), add(&p, dv)
		created, id := add_int(&p, ev.created_at), add(&p, ev.id)
		sql = fmt.tprintf(
			`SELECT count(*) FROM event
			 WHERE pubkey = %s AND kind = %s::integer AND coalesce(d_tag, '') = %s
			   AND (created_at > %s::bigint OR (created_at = %s::bigint AND id <= %s))`,
			pk, kind, dd, created, created, id,
		)
		if first_int(exec(conn, sql, p.values[:]) or_return) != 0 {
			return .Have_Newer, nil
		}

		p = params_make()
		sql = fmt.tprintf(
			"DELETE FROM event WHERE pubkey = %s AND kind = %s::integer AND coalesce(d_tag, '') = %s",
			add(&p, ev.pubkey),
			add_int(&p, ev.kind),
			add(&p, dv),
		)
		exec(conn, sql, p.values[:]) or_return
	}

	p = params_make()
	exp: Maybe(string)
	if e, ok := nostr.expiration(ev); ok {exp = fmt.tprintf("%d", e)}
	sql = fmt.tprintf(
		`INSERT INTO event (id, pubkey, created_at, kind, tagvalues, d_tag, expiration, raw)
		 VALUES (%s, %s, %s::bigint, %s::integer, %s::text[], %s, %s::bigint, %s)
		 ON CONFLICT (id) DO NOTHING`,
		add(&p, ev.id),
		add(&p, ev.pubkey),
		add_int(&p, ev.created_at),
		add_int(&p, ev.kind),
		add(&p, text_array(nostr.tag_index(ev))),
		add(&p, d),
		add(&p, exp),
		add(&p, nostr.event_to_json(ev)),
	)
	r := exec(conn, sql, p.values[:]) or_return
	return .Saved if r.affected > 0 else .Duplicate, nil
}

// Apply a NIP-09 deletion request: remove the referenced events that were
// published by the same author.
db_apply_deletion :: proc(ev: nostr.Event) -> (err: Db_Error) {
	conn := acquire()
	defer release(conn)
	ids := make([dynamic]string, context.temp_allocator)
	for tag in ev.tags {
		if len(tag) < 2 {continue}
		switch tag[0] {
		case "e":
			append(&ids, tag[1])
		case "a":
			parts := strings.split_n(tag[1], ":", 3, context.temp_allocator)
			if len(parts) < 2 || parts[1] != ev.pubkey {continue}
			kind, ok := strconv.parse_i64_of_base(parts[0], 10)
			if !ok {continue}
			d := parts[2] if len(parts) == 3 else ""
			p := params_make()
			sql := fmt.tprintf(
				`DELETE FROM event
				 WHERE pubkey = %s AND kind = %s::integer AND coalesce(d_tag, '') = %s
				   AND created_at <= %s::bigint`,
				add(&p, ev.pubkey),
				add_int(&p, kind),
				add(&p, d),
				add_int(&p, ev.created_at),
			)
			exec(conn, sql, p.values[:]) or_return
		}
	}
	if len(ids) > 0 {
		p := params_make()
		sql := fmt.tprintf(
			"DELETE FROM event WHERE pubkey = %s AND kind <> 5 AND id = ANY(%s::text[])",
			add(&p, ev.pubkey),
			add(&p, text_array(ids[:])),
		)
		exec(conn, sql, p.values[:]) or_return
	}
	return nil
}

// The WHERE clause for one filter.
@(private = "file")
where_clause :: proc(p: ^Params, f: nostr.Filter, now: i64) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "(expiration IS NULL OR expiration > %s::bigint)", add_int(p, now))
	if f.has_ids {
		fmt.sbprintf(&b, " AND id = ANY(%s::text[])", add(p, text_array(f.ids)))
	}
	if f.has_authors {
		fmt.sbprintf(&b, " AND pubkey = ANY(%s::text[])", add(p, text_array(f.authors)))
	}
	if f.has_kinds {
		fmt.sbprintf(&b, " AND kind = ANY(%s::integer[])", add(p, int_array(f.kinds)))
	}
	if since, ok := f.since.?; ok {
		fmt.sbprintf(&b, " AND created_at >= %s::bigint", add_int(p, since))
	}
	if until, ok := f.until.?; ok {
		fmt.sbprintf(&b, " AND created_at <= %s::bigint", add_int(p, until))
	}
	for tf in f.tags {
		values := make([]string, len(tf.values), context.temp_allocator)
		for v, i in tf.values {
			values[i] = strings.concatenate({tf.name, ":", v}, context.temp_allocator)
		}
		fmt.sbprintf(&b, " AND tagvalues && %s::text[]", add(p, text_array(values)))
	}
	return strings.to_string(b)
}

// Stored events matching the filter as raw JSON, newest first.
db_query :: proc(f: nostr.Filter, now: i64, limit: i64) -> (events: []string, err: Db_Error) {
	conn := acquire()
	defer release(conn)
	p := params_make()
	w := where_clause(&p, f, now)
	sql := fmt.tprintf(
		"SELECT raw FROM event WHERE %s ORDER BY created_at DESC, id ASC LIMIT %s::bigint",
		w,
		add_int(&p, limit),
	)
	r := exec(conn, sql, p.values[:]) or_return
	events = make([]string, len(r.rows), context.temp_allocator)
	for row, i in r.rows {
		events[i] = row[0]
	}
	return events, nil
}

// Number of stored events matching any of the filters (NIP-45).
db_count :: proc(filters: []nostr.Filter, now: i64) -> (n: int, err: Db_Error) {
	conn := acquire()
	defer release(conn)
	p := params_make()
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT count(*) FROM event WHERE ")
	for f, i in filters {
		if i > 0 {strings.write_string(&b, " OR ")}
		fmt.sbprintf(&b, "(%s)", where_clause(&p, f, now))
	}
	r := exec(conn, strings.to_string(b), p.values[:]) or_return
	return first_int(r), nil
}

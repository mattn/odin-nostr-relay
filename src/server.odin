package main

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

// HTTP/1.1 and WebSocket (RFC 6455) on top of core:net. No extensions are
// negotiated, so frames never carry compressed data.

WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_HEADER_SIZE :: 16 * 1024
// Room for the frame header on top of the largest accepted message.
MAX_FRAME_SIZE :: MAX_MESSAGE_LENGTH + 1024

Opcode :: enum u8 {
	Continuation = 0x0,
	Text         = 0x1,
	Binary       = 0x2,
	Close        = 0x8,
	Ping         = 0x9,
	Pong         = 0xA,
}

// Buffered reader over a socket. The buffer is heap allocated and owned by
// the connection thread.
Reader :: struct {
	sock: net.TCP_Socket,
	buf:  [dynamic]u8,
	pos:  int,
}

@(private = "file")
fill :: proc(r: ^Reader, want: int) -> bool {
	for len(r.buf) - r.pos < want {
		if r.pos > 0 && r.pos >= len(r.buf) / 2 {
			copy(r.buf[:], r.buf[r.pos:])
			resize(&r.buf, len(r.buf) - r.pos)
			r.pos = 0
		}
		chunk: [16 * 1024]u8
		n, err := net.recv_tcp(r.sock, chunk[:])
		if err != nil || n == 0 {return false}
		append(&r.buf, ..chunk[:n])
	}
	return true
}

// The next `n` bytes. The slice is valid until the next read.
@(private = "file")
read_bytes :: proc(r: ^Reader, n: int) -> ([]u8, bool) {
	if !fill(r, n) {return nil, false}
	out := r.buf[r.pos:][:n]
	r.pos += n
	return out, true
}

Request :: struct {
	method:  string,
	path:    string,
	headers: map[string]string, // lowercase names
}

// Read an HTTP request head. Strings are copied to the temp allocator.
read_request :: proc(r: ^Reader) -> (req: Request, ok: bool) {
	end := -1
	for {
		if i := strings.index(string(r.buf[r.pos:]), "\r\n\r\n"); i >= 0 {
			end = i
			break
		}
		if len(r.buf) - r.pos > MAX_HEADER_SIZE {return req, false}
		fill(r, len(r.buf) - r.pos + 1) or_return
	}
	head := strings.clone(string(r.buf[r.pos:][:end]), context.temp_allocator)
	r.pos += end + 4
	lines := strings.split(head, "\r\n", context.temp_allocator)
	parts := strings.split(lines[0], " ", context.temp_allocator)
	if len(parts) != 3 {return req, false}
	req.method = parts[0]
	req.path = parts[1]
	req.headers = make(map[string]string, context.temp_allocator)
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon < 0 {continue}
		name := strings.to_lower(strings.trim_space(line[:colon]), context.temp_allocator)
		req.headers[name] = strings.trim_space(line[colon + 1:])
	}
	return req, true
}

@(private = "file")
header_has_token :: proc(req: Request, name, token: string) -> bool {
	v := req.headers[name] or_else ""
	for part in strings.split(v, ",", context.temp_allocator) {
		if strings.equal_fold(strings.trim_space(part), token) {return true}
	}
	return false
}

send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	_, err := net.send_tcp(sock, data)
	return err == nil
}

@(private = "file")
respond :: proc(sock: net.TCP_Socket, status: string, headers: []string, body: []u8) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "HTTP/1.1 ")
	strings.write_string(&b, status)
	strings.write_string(&b, "\r\nConnection: close\r\nContent-Length: ")
	strings.write_int(&b, len(body))
	strings.write_string(&b, "\r\n")
	for h in headers {
		strings.write_string(&b, h)
		strings.write_string(&b, "\r\n")
	}
	strings.write_string(&b, "\r\n")
	strings.write_bytes(&b, body)
	send_all(sock, b.buf[:])
}

CORS_HEADERS :: []string {
	"Access-Control-Allow-Origin: *",
	"Access-Control-Allow-Headers: *",
	"Access-Control-Allow-Methods: GET, OPTIONS",
}

@(private = "file")
content_type :: proc(name: string) -> string {
	switch {
	case strings.has_suffix(name, ".html"):
		return "text/html; charset=utf-8"
	case strings.has_suffix(name, ".js"):
		return "text/javascript; charset=utf-8"
	case strings.has_suffix(name, ".css"):
		return "text/css; charset=utf-8"
	case strings.has_suffix(name, ".svg"):
		return "image/svg+xml"
	case strings.has_suffix(name, ".png"):
		return "image/png"
	case strings.has_suffix(name, ".ico"):
		return "image/x-icon"
	case strings.has_suffix(name, ".json"):
		return "application/json"
	}
	return "application/octet-stream"
}

// Serve a top-level file from WEB_ROOT.
@(private = "file")
serve_static :: proc(sock: net.TCP_Socket, req: Request) {
	path := req.path
	if q := strings.index_byte(path, '?'); q >= 0 {path = path[:q]}
	name := path[1:] if len(path) > 0 && path[0] == '/' else path
	if name == "" {name = "index.html"}
	if strings.contains(name, "..") || strings.contains_rune(name, '/') || strings.contains_rune(name, '\\') {
		respond(sock, "404 Not Found", {"Content-Type: text/plain"}, transmute([]u8)string("not found"))
		return
	}
	full := strings.concatenate({config.web_root, "/", name}, context.temp_allocator)
	data, err := os.read_entire_file(full, context.temp_allocator)
	if err != nil {
		respond(sock, "404 Not Found", {"Content-Type: text/plain"}, transmute([]u8)string("not found"))
		return
	}
	ct := strings.concatenate({"Content-Type: ", content_type(name)}, context.temp_allocator)
	respond(sock, "200 OK", {ct}, data)
}

// Entry point of a connection thread.
handle_connection :: proc(sock: net.TCP_Socket) {
	// Per-connection scratch memory. The default temp allocator would keep a
	// zeroed 4 MiB heap block per thread, and glibc keeps that memory
	// resident after the thread exits; a virtual memory arena is unmapped.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 64 * mem.Kilobyte) != nil {
		net.close(sock)
		return
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	defer net.close(sock)
	r := Reader{sock = sock, buf = make([dynamic]u8, 0, 4096)}
	defer delete(r.buf)

	net.set_option(sock, .Receive_Timeout, 30 * time.Second)
	net.set_option(sock, .Send_Timeout, 10 * time.Second)
	req, ok := read_request(&r)
	if !ok {return}

	key := req.headers["sec-websocket-key"] or_else ""
	switch {
	case header_has_token(req, "upgrade", "websocket") && key != "":
		// Clients may stay idle for a long time once subscribed.
		net.set_option(sock, .Receive_Timeout, time.Duration(0))
		accept_websocket(sock, key)
		websocket_session(&r)
	case req.method == "OPTIONS":
		respond(sock, "204 No Content", CORS_HEADERS, nil)
	case strings.contains(req.headers["accept"] or_else "", "application/nostr+json"):
		headers := make([dynamic]string, context.temp_allocator)
		append(&headers, "Content-Type: application/nostr+json")
		append(&headers, ..CORS_HEADERS)
		respond(sock, "200 OK", headers[:], transmute([]u8)nip11_json(config))
	case req.method == "GET" || req.method == "HEAD":
		serve_static(sock, req)
	case:
		respond(sock, "405 Method Not Allowed", nil, nil)
	}
}

@(private = "file")
accept_websocket :: proc(sock: net.TCP_Socket, key: string) {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]u8)key)
	sha1.update(&ctx, transmute([]u8)string(WS_GUID))
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, digest[:])
	accept := base64.encode(digest[:], allocator = context.temp_allocator)
	resp := strings.concatenate(
		{
			"HTTP/1.1 101 Switching Protocols\r\n",
			"Upgrade: websocket\r\n",
			"Connection: Upgrade\r\n",
			"Sec-WebSocket-Accept: ",
			accept,
			"\r\n\r\n",
		},
		context.temp_allocator,
	)
	send_all(sock, transmute([]u8)resp)
}

// Write one unmasked frame. Callers serialize writes to a socket.
ws_write :: proc(sock: net.TCP_Socket, opcode: Opcode, payload: []u8) -> bool {
	header: [10]u8
	header[0] = 0x80 | u8(opcode)
	n := 2
	switch {
	case len(payload) < 126:
		header[1] = u8(len(payload))
	case len(payload) <= 0xFFFF:
		header[1] = 126
		header[2] = u8(len(payload) >> 8)
		header[3] = u8(len(payload))
		n = 4
	case:
		header[1] = 127
		for i in 0 ..< 8 {
			header[2 + i] = u8(u64(len(payload)) >> u64(56 - 8 * i))
		}
		n = 10
	}
	frame := make([]u8, n + len(payload), context.temp_allocator)
	copy(frame, header[:n])
	copy(frame[n:], payload)
	return send_all(sock, frame)
}

@(private = "file")
close_payload :: proc(code: u16, reason: string) -> []u8 {
	out := make([]u8, 2 + len(reason), context.temp_allocator)
	out[0] = u8(code >> 8)
	out[1] = u8(code)
	copy(out[2:], reason)
	return out
}

// Read frames until the connection closes, handing complete text messages
// to the relay.
@(private = "file")
websocket_session :: proc(r: ^Reader) {
	client := client_register(r.sock)
	defer client_unregister(client)

	msg := make([dynamic]u8, 0, 1024)
	defer delete(msg)
	msg_opcode := Opcode.Continuation

	for {
		h := read_bytes(r, 2) or_break
		fin := h[0] & 0x80 != 0
		rsv := h[0] & 0x70
		opcode := Opcode(h[0] & 0x0F)
		masked := h[1] & 0x80 != 0
		length := u64(h[1] & 0x7F)
		if length == 126 {
			ext := read_bytes(r, 2) or_break
			length = u64(ext[0]) << 8 | u64(ext[1])
		} else if length == 127 {
			ext := read_bytes(r, 8) or_break
			length = 0
			for b in ext {length = length << 8 | u64(b)}
		}

		if rsv != 0 || !masked {
			client_close(client, 1002, "protocol error")
			return
		}
		is_control := u8(opcode) >= 0x8
		if is_control && (length > 125 || !fin) {
			client_close(client, 1002, "protocol error")
			return
		}
		if length > MAX_FRAME_SIZE || u64(len(msg)) + length > MAX_FRAME_SIZE {
			client_close(client, 1009, "message too large")
			return
		}

		mask_bytes := read_bytes(r, 4) or_break
		mask: [4]u8
		copy(mask[:], mask_bytes)
		data := read_bytes(r, int(length)) or_break
		for i in 0 ..< len(data) {
			data[i] ~= mask[i & 3]
		}

		#partial switch opcode {
		case .Close:
			code: u16 = 1000
			if len(data) >= 2 {code = u16(data[0]) << 8 | u16(data[1])}
			client_close(client, code, "")
			return
		case .Ping:
			client_write(client, .Pong, data)
			continue
		case .Pong:
			continue
		case .Text, .Binary:
			if msg_opcode != .Continuation {
				client_close(client, 1002, "protocol error")
				return
			}
			msg_opcode = opcode
		case .Continuation:
			if msg_opcode == .Continuation {
				client_close(client, 1002, "protocol error")
				return
			}
		case:
			client_close(client, 1002, "protocol error")
			return
		}

		append(&msg, ..data)
		if !fin {continue}

		if msg_opcode == .Text {
			handle_message(client, string(msg[:]))
		} else {
			client_send(client, notice("error: binary messages are not supported"))
		}
		clear(&msg)
		msg_opcode = .Continuation
		free_all(context.temp_allocator)
		if client_is_closed(client) {return}
	}
	log.debug("connection closed")
}

client_close :: proc(c: ^Client, code: u16, reason: string) {
	client_write(c, .Close, close_payload(code, reason))
}

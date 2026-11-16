package main

import "core:c"

// Minimal libpq bindings.

foreign import pq "system:pq"

PGconn :: struct {}
PGresult :: struct {}

ConnStatusType :: enum c.int {
	CONNECTION_OK  = 0,
	CONNECTION_BAD = 1,
}

ExecStatusType :: enum c.int {
	PGRES_EMPTY_QUERY = 0,
	PGRES_COMMAND_OK  = 1,
	PGRES_TUPLES_OK   = 2,
}

Oid :: c.uint

@(default_calling_convention = "c")
foreign pq {
	PQconnectdb :: proc(conninfo: cstring) -> ^PGconn ---
	PQstatus :: proc(conn: ^PGconn) -> ConnStatusType ---
	PQerrorMessage :: proc(conn: ^PGconn) -> cstring ---
	PQreset :: proc(conn: ^PGconn) ---
	PQfinish :: proc(conn: ^PGconn) ---
	PQexecParams :: proc(conn: ^PGconn, command: cstring, nParams: c.int, paramTypes: [^]Oid, paramValues: [^]cstring, paramLengths: [^]c.int, paramFormats: [^]c.int, resultFormat: c.int) -> ^PGresult ---
	PQresultStatus :: proc(res: ^PGresult) -> ExecStatusType ---
	PQresultErrorMessage :: proc(res: ^PGresult) -> cstring ---
	PQntuples :: proc(res: ^PGresult) -> c.int ---
	PQgetvalue :: proc(res: ^PGresult, row: c.int, col: c.int) -> [^]u8 ---
	PQgetlength :: proc(res: ^PGresult, row: c.int, col: c.int) -> c.int ---
	PQcmdTuples :: proc(res: ^PGresult) -> cstring ---
	PQclear :: proc(res: ^PGresult) ---
}

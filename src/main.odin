package main

import "core:log"
import "core:net"
import "core:os"
import "core:thread"
import "core:time"

main :: proc() {
	context.logger = log.create_console_logger(.Info, {.Level, .Date, .Time})

	config = config_from_env()

	// The database may still be starting up (e.g. under compose).
	for attempt in 1 ..= 30 {
		err := db_open(config.database_url)
		if err == "" {break}
		if attempt == 30 {
			log.fatalf("cannot connect to the database: %s", err)
			os.exit(1)
		}
		log.warnf("database not ready (%s), retrying", err)
		time.sleep(2 * time.Second)
	}
	if err, failed := db_migrate().?; failed {
		log.fatalf("migration failed: %s", err)
		os.exit(1)
	}
	free_all(context.temp_allocator)

	endpoint := net.Endpoint {
		address = net.IP4_Any,
		port    = config.port,
	}
	listener, err := net.listen_tcp(endpoint)
	if err != nil {
		log.fatalf("cannot listen on port %d: %v", config.port, err)
		os.exit(1)
	}
	log.infof("listening on port %d", config.port)

	for {
		sock, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			log.warnf("accept failed: %v", accept_err)
			continue
		}
		thread.create_and_start_with_poly_data(sock, handle_connection, context, self_cleanup = true)
	}
}

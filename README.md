# odin-nostr-relay

A [Nostr](https://github.com/nostr-protocol/nostr) relay written in [Odin](https://odin-lang.org).

- HTTP/1.1 and WebSocket (RFC 6455) implemented from scratch on top of `core:net`
- One thread per connection; new events are matched against the subscriptions of every client and written directly to their sockets
- BIP-340 Schnorr signature verification through [libsecp256k1](https://github.com/bitcoin-core/secp256k1)
- PostgreSQL storage through libpq
- Per-connection scratch memory in a virtual memory arena that is reset after every message

## Supported NIPs

- NIP-01: Basic protocol (including replaceable, ephemeral and addressable events)
- NIP-09: Event deletion
- NIP-11: Relay information document
- NIP-40: Expiration timestamp
- NIP-45: Event counts
- NIP-70: Protected events (rejected, since there is no NIP-42 auth)

## Running

```sh
docker compose up --build
```

The relay listens on port 8080. Configuration is done with environment variables:

| Variable | Default |
| --- | --- |
| `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/nostr` |
| `PORT` | `8080` |
| `WEB_ROOT` | `public` |
| `RELAY_NAME` | `odin-nostr-relay` |
| `RELAY_DESCRIPTION` | `A Nostr relay implemented in Odin` |
| `RELAY_PUBKEY` / `RELAY_CONTACT` / `RELAY_ICON` | (unset) |

## Development

Requires libpq and libsecp256k1 (e.g. `apt install libpq-dev libsecp256k1-dev`).

```sh
odin test nostr
odin build src -out:odin-nostr-relay
./odin-nostr-relay
```

## License

MIT

## Author

Yasuhiro Matsumoto (a.k.a. mattn)

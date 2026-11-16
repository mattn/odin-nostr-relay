FROM debian:trixie-slim AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends clang lld libpq-dev libsecp256k1-dev ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

ARG ODIN_VERSION=dev-2026-11a
RUN curl -fsSL https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-amd64-${ODIN_VERSION}.tar.gz \
  | tar xz -C /opt \
 && ln -s /opt/odin-linux-amd64-*/odin /usr/local/bin/odin

WORKDIR /app
COPY nostr nostr
COPY src src
RUN odin test nostr \
 && odin build src -out:odin-nostr-relay -o:speed -vet -strict-style

FROM debian:trixie-slim

LABEL org.opencontainers.image.source=https://github.com/mattn/odin-nostr-relay \
      org.opencontainers.image.description="A Nostr relay implemented in Odin" \
      org.opencontainers.image.licenses=MIT

RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 libsecp256k1-2 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -r -U relay

COPY --from=build /app/odin-nostr-relay /app/odin-nostr-relay
COPY public /app/public

USER relay
WORKDIR /app
ENV PORT=8080 \
    WEB_ROOT=/app/public
EXPOSE 8080

# Set DATABASE_URL (postgres://user:pass@host:port/db).
CMD ["/app/odin-nostr-relay"]

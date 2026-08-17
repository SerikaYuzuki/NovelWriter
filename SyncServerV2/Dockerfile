FROM rust:1.80-bookworm AS build
WORKDIR /src
COPY . .
RUN cargo build --locked --release

FROM debian:bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 fuminiwa \
    && useradd --system --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin fuminiwa
WORKDIR /app
COPY --from=build /src/target/release/fuminiwa-sync-server-v2 /usr/local/bin/fuminiwa-sync-server-v2
USER fuminiwa
EXPOSE 8092
ENTRYPOINT ["/usr/local/bin/fuminiwa-sync-server-v2"]

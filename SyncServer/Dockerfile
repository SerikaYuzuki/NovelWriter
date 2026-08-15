FROM rust:1.93-bookworm AS builder
WORKDIR /src
COPY Cargo.toml Cargo.lock* ./
COPY src ./src
COPY migrations ./migrations
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/target/release/fuminiwa-sync-server /usr/local/bin/fuminiwa-sync-server
EXPOSE 8080
ENV RUST_LOG=info
CMD ["/usr/local/bin/fuminiwa-sync-server"]

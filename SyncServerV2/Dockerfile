FROM rust:1.80-bookworm AS build
WORKDIR /src
COPY . .
RUN cargo build --release
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/fuminiwa-sync-server-v2 /usr/local/bin/fuminiwa-sync-server-v2
EXPOSE 8092
CMD ["fuminiwa-sync-server-v2"]

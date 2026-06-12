# ---- Stage 1: Build ----
FROM rust:1.82-slim-bookworm AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml .
RUN mkdir src && echo "fn main() {}" > src/main.rs
RUN cargo build --release && rm -rf src

COPY src/ src/
RUN cargo build --release

# ---- Stage 2: Runtime ----
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/target/release/localsend-signaling /app/localsend-signaling

RUN chmod +x /app/localsend-signaling && mkdir -p /var/lib/localsend/uploads

EXPOSE 9000 9001

ENV RUST_LOG=info

CMD ["/app/localsend-signaling"]

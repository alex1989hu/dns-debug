ARG BASE_IMAGE=docker.io/debian:trixie-20260223
ARG TARGETARCH

FROM golang:1.26.1 AS golang-builder

RUN go install github.com/domsolutions/gopayloader@master
RUN go install github.com/rs/dnstrace@latest

FROM rust:1.94.1-trixie AS rust-builder

WORKDIR /build

RUN apt-get update && apt-get install -y clang cmake
RUN git clone --depth=1 https://github.com/cloudflare/quiche.git
RUN <<'EOF'
cd /build/quiche
cargo build --release --bin quiche-client
EOF

FROM $BASE_IMAGE AS base

FROM base AS builder

ARG TARGETARCH

RUN <<'EOF'
apt-get update && apt-get install -y ca-certificates curl git zlib1g-dev make gcc

case "${TARGETARCH}" in
    amd64)  ARCH="amd64" ;;
    arm64)  ARCH="arm64" ;;
    *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;;
esac
EOF

WORKDIR /build

RUN curl -Lo /build/mc "https://dl.min.io/client/mc/release/linux-${TARGETARCH}/mc"
RUN curl -Lo /build/kubectl "https://dl.k8s.io/release/v1.35.0/bin/linux/${TARGETARCH}/kubectl"
RUN curl -Lo /build/bombardier "https://github.com/codesenberg/bombardier/releases/download/v2.0.2/bombardier-linux-${TARGETARCH}"

RUN git clone --depth=1 https://github.com/rbsec/sslscan.git
RUN <<'EOF'
cd /build/sslscan
make static
strip --strip-all /build/sslscan/sslscan
EOF

FROM base AS production

ARG DEBIAN_FRONTEND=noninteractive
ARG PIP_NO_CACHE_DIR=1
ARG TARGETARCH

COPY --from=builder --chmod=0755 --chown=0:0 /build/kubectl /usr/local/bin/kubectl
COPY --from=builder --chmod=0755 --chown=0:0 /build/mc /usr/local/bin/mc
COPY --from=builder --chmod=0755 --chown=0:0 /build/sslscan/sslscan /usr/local/bin/sslscan
COPY --from=builder --chmod=0755 --chown=0:0 /build/bombardier /usr/local/bin/bombardier
COPY --from=docker.io/mikefarah/yq:4.52.2 --chmod=0755 --chown=0:0 /usr/bin/yq /usr/local/bin/yq
COPY --from=ghcr.io/jqlang/jq:1.8.1 --chmod=0755 --chown=0:0 /jq /usr/local/bin/jq
COPY --from=golang-builder --chmod=0755 --chown=0:0 /go/bin/dnstrace /usr/local/bin/dnstrace
COPY --from=golang-builder --chmod=0755 --chown=0:0 /go/bin/gopayloader /usr/local/bin/gopayloader
COPY --from=rust-builder --chmod=0755 --chown=0:0 /build/quiche/target/release/quiche-client /usr/local/bin/quiche-client

RUN --mount=type=bind,source=requirements.txt,target=/tmp/requirements.txt <<'EOF'
set -euxo pipefail

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg postgresql-common

curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg

cat <<'CAT_EOF' > /etc/apt/sources.list.d/mongodb-org-8.0.list
deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main
CAT_EOF

cat > /etc/mongosh.conf <<'CFG_EOF'
mongosh:
  enableTelemetry: false
  forceDisableTelemetry: true
CFG_EOF

install -d /usr/share/postgresql-common/pgdg

. /etc/os-release
sh -c "echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main' > /etc/apt/sources.list.d/pgdg.list"

apt-get update
apt-get install -y --no-install-recommends bash-completion chrony dnsutils lsof mtr netcat-traditional nmap mongodb-mongosh postgresql-18 python3 python3-pip traceroute
apt-get clean all
apt-get purge -y
rm -rf /var/lib/apt/lists/*

pip install --break-system-packages --no-cache-dir -r /tmp/requirements.txt
groupadd --gid 10001 dns
useradd --no-log-init --uid 10001 --gid 10001 dns
EOF

ENV RUST_LOG=trace
ENV MONGOSH_DISABLE_TELEMETRY=1

USER 10001

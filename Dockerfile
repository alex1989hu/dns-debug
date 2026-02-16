ARG BASE_IMAGE=almalinux:9.7-20260129
ARG TARGETARCH

FROM golang:1.26.0 AS golang-builder

RUN go install github.com/domsolutions/gopayloader@master
RUN go install github.com/rs/dnstrace@latest

FROM rust:1.93.1-trixie AS rust-builder

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
dnf update -y
dnf install -y gcc git make openssl-devel perl zlib-devel

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

RUN <<'EOF'
curl https://pgp.mongodb.com/mongosh.asc | gpg --import
rpm --import https://pgp.mongodb.com/mongosh.asc


cat <<'CAT_EOF' > /etc/yum.repos.d/mongodb-org-8.2.repo
[mongodb-org-8.2]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/8/mongodb-org/8.2/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-8.0.asc
CAT_EOF

dnf update -y

if [ "$TARGETARCH" = "amd64" ]; then
    dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
elif [ "$TARGETARCH" = "arm64" ]; then
    dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-aarch64/pgdg-redhat-repo-latest.noarch.rpm
else
    echo "Unsupported architecture: $TARGETARCH" && exit 1 ;
fi

dnf install -y bash-completion bind-utils chrony lsof mtr nmap nmap-ncat mongodb-mongosh procps-ng postgresql18 traceroute zlib
dnf clean all
groupadd --gid 10001 dns
useradd --no-log-init --uid 10001 --gid 10001 dns
EOF

ENV RUST_LOG=trace

USER 10001

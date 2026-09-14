# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=skip=InvalidDefaultArgInFrom
# mica-build-rust -- rustc, cargo, clippy and rustfmt from sha256-pinned
# standalone tarballs (not rustup, which would honour a consumer's
# rust-toolchain.toml), with std and a linker for both architectures so it can
# cross-build, plus the gate tools: sha256-pinned cargo-nextest and cargo-deny,
# and dbus-daemon. Built on mica-build-c.
ARG MICA_BASE_IMAGE

FROM ${MICA_BASE_IMAGE} AS fetch

COPY images.lock /etc/mica-build/images.env

RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-mica-build-rust-fetch,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-mica-build-rust-fetch,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends curl

# Set a RUST_*SHA256_<arch> to PENDING to have this stage print the hash to record.
ARG TARGETARCH
RUN --mount=type=cache,target=/var/cache/mos-fetch,id=mos-fetch-rust,sharing=locked \
    --mount=type=bind,from=mos-lib,target=/tmp/mos-lib \
    --mount=type=bind,source=fetch.sh,target=/tmp/fetch.sh \
    bash /tmp/fetch.sh

FROM ${MICA_BASE_IMAGE} AS final

COPY images.lock /etc/mica-build/images.env
COPY --from=fetch /opt/rust /opt/rust
COPY --from=fetch /opt/cargo-bin/ /usr/local/cargo/bin/

# dbus-daemon: several micad and apid tests fail rather than skip without a session bus.
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-mica-build-rust,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-mica-build-rust,sharing=locked \
    --mount=type=bind,source=install-linker.sh,target=/tmp/install-linker.sh \
    bash /tmp/install-linker.sh && \
    apt-get install -y --no-install-recommends dbus

# CARGO_HOME matches the registry cache mounts consumers already use. Linkers are
# env defaults so a consumer's .cargo/config.toml still wins.
ENV RUSTUP_HOME=/nonexistent \
    CARGO_HOME=/usr/local/cargo \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc \
    PATH="/opt/rust/bin:/usr/local/cargo/bin:${PATH}"

ARG MICA_BASE_IMAGE
ARG TARGETARCH
RUN --mount=type=bind,from=mos-lib,target=/tmp/mos-lib \
    --mount=type=bind,source=assert.sh,target=/tmp/assert.sh \
    bash /tmp/assert.sh

LABEL org.opencontainers.image.title="mica-build-rust" \
      org.opencontainers.image.description="mos Rust toolchain and gate tools, sha256-pinned tarballs, cross-capable" \
      org.opencontainers.image.base.name="${MICA_BASE_IMAGE}" \
      com.mos.build-env.source="build-env/rust/Dockerfile" \
      com.mos.build-env.pins="build-env/images.env"

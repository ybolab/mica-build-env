# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=skip=InvalidDefaultArgInFrom
# mica-build-c -- the native C and C++ toolchain, on top of mica-build-base;
# mica-build-go and mica-build-rust build on it.
# Component-specific -dev packages belong in the consumer's own stage.
ARG MICA_BASE_IMAGE

FROM ${MICA_BASE_IMAGE} AS final

# Replaces the parent's lock: base's keys are already recorded in base.env.
COPY images.lock /etc/mica-build/images.env

# build-essential rather than a hand-picked list, so libc headers cannot go missing.
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-mica-build-c,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-mica-build-c,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        pkgconf \
        autoconf \
        automake \
        libtool \
        ccache \
        python3

# ccache only survives a layer invalidation if the consumer mounts /ccache as a cache.
ENV CCACHE_DIR=/ccache \
    PATH="/usr/lib/ccache:${PATH}"

ARG MICA_BASE_IMAGE
ARG TARGETARCH
RUN --mount=type=bind,from=mos-lib,target=/tmp/mos-lib \
    --mount=type=bind,source=assert.sh,target=/tmp/assert.sh \
    bash /tmp/assert.sh

LABEL org.opencontainers.image.title="mica-build-c" \
      org.opencontainers.image.description="mos C/C++ toolchain" \
      org.opencontainers.image.base.name="${MICA_BASE_IMAGE}" \
      com.mos.build-env.source="build-env/c/Dockerfile" \
      com.mos.build-env.pins="build-env/images.env"

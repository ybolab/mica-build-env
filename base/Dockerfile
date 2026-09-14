# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=skip=InvalidDefaultArgInFrom
# mica-build-base -- the floor every mos builder image stands on: the basic
# system tools (ca-certificates, git, file, binutils, xz, curl, wget, openssl,
# jq, the Debian packaging tools, mmdebstrap) and a sha256-pinned bun. mica-build-c builds
# on it. Built by build.sh.

# No default: a driver that forgets the argument must fail, not build from a floating tag.
ARG MICA_BASE_IMAGE

FROM ${MICA_BASE_IMAGE} AS fetch

COPY images.lock /etc/mica-build/images.env

RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-mica-build-base-fetch,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-mica-build-base-fetch,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip

ARG TARGETARCH
RUN --mount=type=cache,target=/var/cache/mos-fetch,id=mos-fetch-bun,sharing=locked \
    --mount=type=bind,from=mos-lib,target=/tmp/mos-lib \
    --mount=type=bind,source=fetch.sh,target=/tmp/fetch.sh \
    bash /tmp/fetch.sh

FROM ${MICA_BASE_IMAGE} AS base

# The filtered, comment-stripped lock build.sh writes, so unrelated pins and
# prose in images.env do not invalidate this layer.
COPY images.lock /etc/mica-build/images.env

# docker-clean is removed so the apt cache mount keeps the downloaded .debs.
# openssl is named although ca-certificates pulls it in, so the version that
# mints keys is declared, floored and recorded.
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-mica-build-base,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-mica-build-base,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        file \
        binutils \
        xz-utils \
        curl \
        wget \
        openssl \
        jq \
        dpkg-dev \
        mmdebstrap

COPY --from=fetch /opt/bun/bin/bun /usr/local/bin/bun

ARG MICA_BASE_IMAGE
ARG TARGETARCH
RUN --mount=type=bind,from=mos-lib,target=/tmp/mos-lib \
    --mount=type=bind,source=assert.sh,target=/tmp/assert.sh \
    bash /tmp/assert.sh

LABEL org.opencontainers.image.title="mica-build-base" \
      org.opencontainers.image.description="mos common build floor: system tools, Debian packaging, mmdebstrap, openssl, jq, bun" \
      org.opencontainers.image.base.name="${MICA_BASE_IMAGE}" \
      com.mos.build-env.source="build-env/base/Dockerfile" \
      com.mos.build-env.pins="build-env/images.env"

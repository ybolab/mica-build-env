# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=skip=InvalidDefaultArgInFrom
# mica-build-go -- the Go toolchain from a sha256-pinned upstream tarball, on
# top of mica-build-c, whose C toolchain cgo uses. curl stays in the fetch stage.
ARG MICA_BASE_IMAGE

FROM ${MICA_BASE_IMAGE} AS fetch

COPY images.lock /etc/mica-build/images.env

RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-mica-build-go-fetch,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-mica-build-go-fetch,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends curl

# Set GO_SHA256_<arch> to PENDING to have this stage print the hash to record.
ARG TARGETARCH
RUN --mount=type=cache,target=/var/cache/mos-fetch,id=mos-fetch-go,sharing=locked \
    --mount=type=bind,from=mos-lib,target=/tmp/mos-lib \
    --mount=type=bind,source=fetch.sh,target=/tmp/fetch.sh \
    bash /tmp/fetch.sh

FROM ${MICA_BASE_IMAGE} AS final

COPY images.lock /etc/mica-build/images.env
COPY --from=fetch /opt/go /opt/go

# GOTOOLCHAIN=local keeps a go.mod from swapping in a downloaded toolchain;
# assert.sh refuses an image without it. GOPATH=/go matches consumers' cache mounts.
ENV GOROOT=/opt/go \
    GOPATH=/go \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=readonly \
    PATH="/opt/go/bin:/go/bin:${PATH}"

ARG MICA_BASE_IMAGE
ARG TARGETARCH
RUN --mount=type=bind,from=mos-lib,target=/tmp/mos-lib \
    --mount=type=bind,source=assert.sh,target=/tmp/assert.sh \
    bash /tmp/assert.sh

LABEL org.opencontainers.image.title="mica-build-go" \
      org.opencontainers.image.description="mos Go toolchain, sha256-pinned tarball" \
      org.opencontainers.image.base.name="${MICA_BASE_IMAGE}" \
      com.mos.build-env.source="build-env/go/Dockerfile" \
      com.mos.build-env.pins="build-env/images.env"

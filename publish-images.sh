#!/usr/bin/env bash
# Publish the build-env images to GHCR as multi-architecture images and write
# the build-env-image.lock a release carries: one IMAGE_MICA_BUILD_* reference per image.
#
#   bash publish-images.sh --out <file>             build what is not published for these inputs, push, write the env
#   bash publish-images.sh --resolve --out <file>   build nothing; write the env or refuse if an image is not published
#
# Publishing is CI's: the images job of .github/workflows/release.yml, run when
# a release is published (`docker login ghcr.io` with packages: write). base builds on
# IMAGE_DEBIAN_TRIXIE, c on base, go and rust on c. An image's inputs are its images.env keys, its parent's published
# reference, its Dockerfile, dockerignore and the scripts that allow-list
# admits, and lib/; the image is this repository's package tagged
# <image>.inputs-<sha256 prefix> of them (and <image>.build-<commit12>; the
# per-architecture sources are <image>.<arch>.build-<commit12>). A tag that
# exists is never rebuilt or re-pointed. Every reference written reads with no
# credential and lists both architectures.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_ENV="${HERE}/images.env"
REPOSITORY="${MICA_IMAGES_REPOSITORY:-ghcr.io/ybolab/mica-build-env}"
ARCHES=(amd64 arm64)

# <image>|<images.env key prefixes>|<parent: an images.env key or an earlier image>
IMAGES=(
    "base|BASE_,DEB_,OPENSSL_|IMAGE_DEBIAN_TRIXIE"
    "c|C_|base"
    "go|GO_|c"
    "rust|RUST_,RUSTCHECK_|c"
)

USAGE="usage: bash publish-images.sh [--resolve] --out <file>"
MODE=publish
OUT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --resolve) MODE=resolve; shift ;;
    --out) OUT="${2-}"; [ -n "${OUT}" ] || { echo "${USAGE}" >&2; exit 1; }; shift 2 ;;
    *) echo "${USAGE}" >&2; exit 1 ;;
    esac
done
[ -n "${OUT}" ] || { echo "${USAGE}" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "error: docker is required and not on PATH" >&2; exit 1; }

STRIPPED="$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${IMAGES_ENV}")"
# shellcheck disable=SC1090
. <(printf '%s\n' "${STRIPPED}")

env_key() { local k="${1^^}"; printf 'IMAGE_MICA_BUILD_%s\n' "${k//-/_}"; }

# inputs_tag <image> <prefixes> <parent ref>
inputs_tag() {
    local name="$1" prefixes="$2" parent="$3" p f sha
    local -a pfx files
    IFS=',' read -r -a pfx <<<"${prefixes}"
    mapfile -t files < <(sed -n 's/^!\(.*\)$/\1/p' "${HERE}/${name}/Dockerfile.dockerignore" | grep -vx 'images.lock')
    sha="$(
        cd "${HERE}"
        for p in "${pfx[@]}"; do
            printf '%s\n' "${STRIPPED}" | sed -n "s/^\(${p}[A-Za-z0-9_]*=.*\)$/\1/p"
        done
        printf 'MICA_BASE_IMAGE=%s\n' "${parent}"
        cat "${name}/Dockerfile" "${name}/Dockerfile.dockerignore"
        for f in "${files[@]}"; do cat "${name}/${f}"; done
        cat lib/*
    )"
    sha="$(printf '%s\n' "${sha}" | sha256sum | cut -d' ' -f1)"
    printf '%s.inputs-%s\n' "${name}" "${sha:0:16}"
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/anon"

# Captured whole before parsing (pipefail), as build.sh's resolve_digest does.
index_digest() {
    local out
    out="$(docker buildx imagetools inspect "$1" 2>/dev/null)" || return 1
    printf '%s\n' "${out}" | awk '/^Digest:[[:space:]]/{print $2; exit}'
}
# Public, always: read with an empty docker configuration.
anon_digest() { DOCKER_CONFIG="${WORK}/anon" index_digest "$1"; }

if [ "${MODE}" = publish ]; then
    command -v git >/dev/null 2>&1 || { echo "error: git is required and not on PATH" >&2; exit 1; }
    [ -z "$(git -C "${HERE}" status --porcelain)" ] || {
        echo "error: ${HERE} has uncommitted changes; the published tags name a commit, so they are built from a clean one" >&2
        exit 1
    }
    COMMIT="$(git -C "${HERE}" rev-parse HEAD)"
fi

declare -A REF=()
for row in "${IMAGES[@]}"; do
    IFS='|' read -r name prefixes parent <<<"${row}"
    case "${parent}" in
    IMAGE_*) from="${!parent-}" ;;
    *) from="${REF[${parent}]}" ;;
    esac
    [ -n "${from}" ] || { echo "error: ${name}'s parent ${parent} resolved to nothing" >&2; exit 1; }
    tag="$(inputs_tag "${name}" "${prefixes}" "${from}")"

    if digest="$(anon_digest "${REPOSITORY}:${tag}")" && [ -n "${digest}" ]; then
        echo "publish-images: ${REPOSITORY}:${tag} is published" >&2
        REF["${name}"]="${REPOSITORY}:${tag}@${digest}"
        continue
    fi
    [ "${MODE}" = publish ] || {
        echo "error: ${REPOSITORY}:${tag} (${name}) is not published or does not read anonymously; the release workflow's images job builds it for this commit's tag" >&2
        exit 1
    }

    sources=()
    for arch in "${ARCHES[@]}"; do
        src="${REPOSITORY}:${name}.${arch}.build-${COMMIT:0:12}"
        if [ "${parent#IMAGE_}" = "${parent}" ]; then
            MICA_BUILD_PLATFORM="linux/${arch}" MICA_BUILD_PARENT="${from}" bash "${HERE}/build.sh" "${name}" >&2
        else
            MICA_BUILD_PLATFORM="linux/${arch}" bash "${HERE}/build.sh" "${name}" >&2
        fi
        docker tag "localhost/mica-build-${name}:${arch}" "${src}"
        # A push that reports success is read back; the registry has answered
        # 404 for a tag it just accepted, so a missing tag is pushed again.
        for try in 1 2 3 4 5; do
            docker push -q "${src}" >&2
            index_digest "${src}" >/dev/null && break
            [ "${try}" -lt 5 ] || { echo "error: ${src} was pushed ${try} times and still does not resolve" >&2; exit 1; }
            echo "publish-images: ${src} does not resolve after the push; pushing again" >&2
            sleep $((try * 5))
        done
        sources+=("${src}")
    done
    docker buildx imagetools create -t "${REPOSITORY}:${tag}" -t "${REPOSITORY}:${name}.build-${COMMIT:0:12}" "${sources[@]}" >&2
    digest="$(anon_digest "${REPOSITORY}:${tag}")" && [ -n "${digest}" ] || {
        package="${REPOSITORY#*/}"
        echo "error: ${REPOSITORY}:${tag} was pushed and does not read anonymously. If the package is private, set it public once at https://github.com/orgs/${package%%/*}/packages/container/package/${package#*/} (Package settings, Danger Zone, Change visibility: Public) and rerun" >&2
        exit 1
    }
    REF["${name}"]="${REPOSITORY}:${tag}@${digest}"
done

for row in "${IMAGES[@]}"; do
    name="${row%%|*}"
    out="$(DOCKER_CONFIG="${WORK}/anon" docker buildx imagetools inspect "${REF[${name}]}")"
    for arch in "${ARCHES[@]}"; do
        printf '%s\n' "${out}" | grep -c "linux/${arch}" >/dev/null || {
            echo "error: ${REF[${name}]} lists no linux/${arch} manifest" >&2
            exit 1
        }
    done
done

{
    echo "# build-env-image.lock: the mica-build-env images, amd64 and arm64, public; generated by publish-images.sh."
    for row in "${IMAGES[@]}"; do
        name="${row%%|*}"
        echo "$(env_key "${name}")=${REF[${name}]}"
    done
} >"${OUT}"
echo "publish-images: wrote ${OUT}" >&2

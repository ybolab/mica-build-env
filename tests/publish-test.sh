#!/usr/bin/env bash
# publish-images.sh --resolve and publish-release.sh against a copy of this
# tree, with gh, docker and curl replaced by stubs: which inputs move which
# image, the generated build-env-image.lock, and every refusal of a release before
# anything is written.
#
#   bash tests/publish-test.sh      (no network, no docker)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
for t in git sha256sum tar; do
    command -v "${t}" >/dev/null 2>&1 || { echo "error: ${t} is required" >&2; exit 1; }
done
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASS_N=0
FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $1"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $1"; }
says() { grep -c -- "$2" "$1" >/dev/null; }

# ------------------------------------------------------------ a copy of this tree
BE="${WORK}/repo"
mkdir -p "${BE}"
(cd "${REPO}" && git ls-files -co --exclude-standard -z | tar -cf - --null --no-recursion -T -) | tar -xf - -C "${BE}"
g() { git -C "${BE}" -c user.name=test -c user.email=test@example.invalid "$@"; }
g init -q -b main
g add -A
g commit -q -m fixture

# ------------------------------------------------------------ stubs
# docker: `buildx imagetools inspect <ref>` answers for a published tag (any tag
# with STUB_ALL=1, else the tags listed in STUB_PUBLISHED) with a digest derived
# from the tag, so a changed tag changes its children's inputs as a real one does.
STUBS="${WORK}/stubs"
LOG="${WORK}/calls"
UP="${WORK}/uploaded"
PUBLISHED="${WORK}/published"
mkdir -p "${STUBS}" "${UP}"
: >"${PUBLISHED}"
cat >"${STUBS}/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"${STUB_LOG}"
[ -z "${STUB_DOCKER_FAIL-}" ] || exit 1
[ "$1 $2 $3" = "buildx imagetools inspect" ] || { echo "stub docker: unexpected $*" >&2; exit 2; }
ref="${4%@*}"
tag="${ref##*:}"
[ -n "${STUB_ALL-}" ] || grep -cx "${tag}" "${STUB_PUBLISHED}" >/dev/null || exit 1
printf 'Name: %s\nMediaType: application/vnd.oci.image.index.v1+json\nDigest: sha256:%s\n\nManifests:\n  Platform: linux/amd64\n  Platform: linux/arm64\n' \
    "$4" "$(printf '%s' "${tag}" | sha256sum | cut -d' ' -f1)"
STUB
cat >"${STUBS}/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"${STUB_LOG}"
case "$1 $2" in
api\ repos/*/git/ref/tags/*)
    if [ -n "${STUB_GH_ERR-}" ]; then echo "gh: Bad Gateway (${STUB_GH_ERR})" >&2; exit 1; fi
    if [ -n "${STUB_TAG_SHA-}" ]; then printf '{"object":{"type":"commit","sha":"%s"}}\n' "${STUB_TAG_SHA}"; exit 0; fi
    echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
api\ repos/*/releases/tags/*)
    # The release being attached (STUB_TAG_UP) carries STUB_ASSETS; an earlier one
    # carries build-env-image.lock when listed in STUB_LOCK_TAGS, else images.env.
    tag="${2##*/}"
    if [ "${tag}" = "${STUB_TAG_UP}" ]; then
        [ -z "${STUB_NO_RELEASE-}" ] || { echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        assets="${STUB_ASSETS-}"
    elif printf ' %s ' "${STUB_LOCK_TAGS-}" | grep -c " ${tag} " >/dev/null; then
        assets=build-env-image.lock
    else
        assets=images.env
    fi
    jq -n --arg body "${STUB_BODY-}" --arg assets "${assets}" '{body: $body, assets: [$assets | split(" ")[] | select(. != "") | {name: .}]}' ;;
"release list") printf '%s\n' ${STUB_RELEASES-} ;;
"release upload")
    for a in "$@"; do [ -f "${a}" ] && cp "${a}" "${STUB_UP}/"; done
    exit 0 ;;
"release edit") exit 0 ;;
*) echo "stub gh: unexpected $*" >&2; exit 2 ;;
esac
STUB
cat >"${STUBS}/curl" <<'STUB'
#!/usr/bin/env bash
# Serves a previous release's build-env-image.lock (STUB_PREV_TAG, STUB_PREV_ENV) and what
# `gh release upload` stored in STUB_UP; every other download fails.
echo "curl $*" >>"${STUB_LOG}"
out=""; url=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done
file="${url##*/}"; rest="${url%/*}"; tag="${rest##*/}"
if [ -n "${STUB_PREV_TAG-}" ] && [ "${tag}" = "${STUB_PREV_TAG}" ] && [ "${file}" = build-env-image.lock ] && [ -n "${STUB_PREV_ENV-}" ]; then
    cp "${STUB_PREV_ENV}" "${out}"; exit 0
fi
if [ -n "${STUB_TAG_UP-}" ] && [ "${tag}" = "${STUB_TAG_UP}" ] && [ -f "${STUB_UP}/${file}" ]; then
    cp "${STUB_UP}/${file}" "${out}"; exit 0
fi
exit 22
STUB
chmod +x "${STUBS}"/*
export PATH="${STUBS}:${PATH}" STUB_LOG="${LOG}" STUB_UP="${UP}" STUB_PUBLISHED="${PUBLISHED}"

# ------------------------------------------------------------ publish-images.sh --resolve
resolve() { # resolve OUT: exit status of --resolve, its output in ${WORK}/resolve.out
    : >"${LOG}"
    rm -f "$1"
    (cd "${BE}" && bash publish-images.sh --resolve --out "$1") >"${WORK}/resolve.out" 2>&1
}

if resolve "${WORK}/none.env"; then
    fail "--resolve succeeds with nothing published"
elif says "${WORK}/resolve.out" "mica-build-env:base.inputs-" && [ ! -e "${WORK}/none.env" ]; then
    pass "--resolve with nothing published refuses at base and writes nothing"
else
    fail "--resolve with nothing published: $(tail -n2 "${WORK}/resolve.out" | tr '\n' ' ')"
fi
base_tag="$(sed -n 's/.*mica-build-env:\(base\.inputs-[0-9a-f]*\).*/\1/p' "${WORK}/resolve.out" | head -n1)"
printf '%s\n' "${base_tag}" >"${PUBLISHED}"
if ! resolve "${WORK}/base.env" && says "${WORK}/resolve.out" "mica-build-env:c.inputs-.* (c) is not published"; then
    pass "--resolve with only base published refuses at c"
else
    fail "--resolve with only base published: $(tail -n2 "${WORK}/resolve.out" | tr '\n' ' ')"
fi
if says "${LOG}" "docker push" || says "${LOG}" "imagetools create" || says "${LOG}" "buildx build"; then fail "--resolve builds or pushes: $(cat "${LOG}")"; else pass "--resolve builds and pushes nothing"; fi

export STUB_ALL=1
if resolve "${WORK}/good.env"; then pass "--resolve writes the env once every image is published"; else fail "--resolve: $(tail -n2 "${WORK}/resolve.out" | tr '\n' ' ')"; fi
keys="$(sed -n 's/^\(IMAGE_MICA_BUILD_[A-Z_]*\)=ghcr\.io\/ybolab\/mica-build-env:[a-z-]*\.inputs-[0-9a-f]\{16\}@sha256:[0-9a-f]\{64\}$/\1/p' "${WORK}/good.env" | tr '\n' ' ')"
if [ "${keys}" = "IMAGE_MICA_BUILD_BASE IMAGE_MICA_BUILD_C IMAGE_MICA_BUILD_GO IMAGE_MICA_BUILD_RUST " ] &&
    [ "$(grep -vc '^#' "${WORK}/good.env")" = 4 ]; then
    pass "the generated env holds exactly the four build-env image references"
else
    fail "the generated env: $(cat "${WORK}/good.env")"
fi

moved() { # moved LABEL EXPECTED: resolve after a change, compare the moved keys, restore the tree
    local got
    resolve "${WORK}/moved.env" || true
    got="$({ diff "${WORK}/good.env" "${WORK}/moved.env" || true; } | sed -n 's/^> \(IMAGE_MICA_BUILD_[A-Z_]*\)=.*/\1/p' | sort | tr '\n' ' ' | sed 's/ $//')"
    if [ "${got}" = "$2" ]; then pass "$1 -> moves: ${2:-none}"; else fail "$1 -> moves: '${got}', want '$2'"; fi
    g checkout -q -- .
}

printf '\n# probe\n' >>"${BE}/go/assert.sh"
moved "go/assert.sh changes" "IMAGE_MICA_BUILD_GO"

sed -i 's/^C_FLOOR_GCC_MIN=.*/C_FLOOR_GCC_MIN=14.3/' "${BE}/images.env"
moved "a C_ floor changes" "IMAGE_MICA_BUILD_C IMAGE_MICA_BUILD_GO IMAGE_MICA_BUILD_RUST"

sed -i 's/^OPENSSL_FLOOR_JQ_MIN=.*/OPENSSL_FLOOR_JQ_MIN=1.8/' "${BE}/images.env"
moved "an OPENSSL_ floor changes (base carries openssl and jq)" "IMAGE_MICA_BUILD_BASE IMAGE_MICA_BUILD_C IMAGE_MICA_BUILD_GO IMAGE_MICA_BUILD_RUST"

sed -i 's/^RUSTCHECK_DENY_VERSION=.*/RUSTCHECK_DENY_VERSION=0.19.10/' "${BE}/images.env"
moved "a gate tool pin changes (rust carries the gate tools)" "IMAGE_MICA_BUILD_RUST"

sed -i 's/^RUST_VERSION=.*/RUST_VERSION=1.99.0/' "${BE}/images.env"
moved "RUST_VERSION changes" "IMAGE_MICA_BUILD_RUST"

sed -i 's/^IMAGE_DEBIAN_TRIXIE=.*/IMAGE_DEBIAN_TRIXIE=debian:trixie-slim@sha256:'"$(printf trixie | sha256sum | cut -d' ' -f1)"'/' "${BE}/images.env"
moved "the Debian base pin changes" "IMAGE_MICA_BUILD_BASE IMAGE_MICA_BUILD_C IMAGE_MICA_BUILD_GO IMAGE_MICA_BUILD_RUST"

printf '\n# probe\n' >>"${BE}/lib/common.sh"
moved "lib/common.sh changes" "IMAGE_MICA_BUILD_BASE IMAGE_MICA_BUILD_C IMAGE_MICA_BUILD_GO IMAGE_MICA_BUILD_RUST"

printf '\n# probe\n' >>"${BE}/publish-release.sh"
moved "a script no image copies changes" ""

# ------------------------------------------------------------ publish-release.sh
release() { # release LABEL WANT_RC PATTERN TAG: run with the stubs, check rc and output
    : >"${LOG}"
    rm -f "${UP}"/*
    local rc=0
    (cd "${BE}" && bash publish-release.sh "$4") >"${WORK}/release.out" 2>&1 || rc=$?
    if [ "${rc}" != "$2" ]; then
        fail "$1: exit ${rc}, want $2: $(tail -n3 "${WORK}/release.out" | tr '\n' ' ')"
    elif ! says "${WORK}/release.out" "$3"; then
        fail "$1: output lacks '$3': $(tail -n3 "${WORK}/release.out" | tr '\n' ' ')"
    else
        pass "$1"
    fi
}
no_call() { if says "${LOG}" "$2"; then fail "$1: '$2' was called"; else pass "$1"; fi; }
none_called() { if [ -s "${LOG}" ]; then fail "$1: $(tr '\n' ' ' <"${LOG}")"; else pass "$1"; fi; }
nothing_written() { if says "${LOG}" "release upload" || says "${LOG}" "release edit"; then fail "$1: $(grep 'release \(upload\|edit\)' "${LOG}")"; else pass "$1"; fi; }

T0=20260101-0000
T1=20260102-0304
printf '\n' >>"${BE}/README.md"
g commit -q -am tagged
g update-ref refs/remotes/origin/main HEAD
HEAD_SHA="$(g rev-parse HEAD)"
export STUB_TAG_SHA="${HEAD_SHA}" STUB_TAG_UP="${T1}"

release "a tag that is not YYYYMMDD-HHMM is refused" 1 "not a UTC time YYYYMMDD-HHMM" v0.0.1
none_called "... and nothing was asked of gh"
release "a time tag without the dash is refused" 1 "not a UTC time YYYYMMDD-HHMM" 202601020304
release "a tag that is not a real time is refused" 1 "not a UTC time YYYYMMDD-HHMM" 20261301-1200
release "a tag in the future is refused" 1 "a time in the future" 20990101-0000
none_called "... and nothing was asked of gh"
STUB_TAG_SHA="" release "a tag that does not exist is refused" 1 "cut the release with gh release create" "${T1}"
nothing_written "... and nothing is written"
STUB_GH_ERR="HTTP 502" release "a tag lookup that fails other than 404 is refused" 1 "could not read ${T1}" "${T1}"
STUB_TAG_SHA="$(printf '%040d' 7)" release "a tag on another commit is refused" 1 "not the checked-out commit" "${T1}"
STUB_NO_RELEASE=1 release "a tag without a published release is refused" 1 "has no published release" "${T1}"
STUB_ASSETS="build-env-image.lock" release "a release that already carries an asset is refused" 1 "an asset is never replaced" "${T1}"
nothing_written "... and nothing is written"

g update-ref refs/remotes/origin/main HEAD~1
release "a tagged commit that is not on main is refused" 1 "is not on origin/main" "${T1}"
g update-ref refs/remotes/origin/main HEAD

printf 'dirty\n' >>"${BE}/README.md"
release "a dirty tree is refused" 1 "uncommitted changes" "${T1}"
no_call "... before any release is listed" "release list"
g checkout -q -- .

STUB_RELEASES="${T1} 20261231-2359 v0.0.1" release "a release later than the tag is refused" 1 "the release 20261231-2359 is later than ${T1}" "${T1}"
no_call "... before any image is read" "docker"

STUB_ALL="" release "a tag whose images are not published is refused" 1 "the images job publishes them for ${T1}" "${T1}"
nothing_written "... and nothing is written"
STUB_DOCKER_FAIL=1 release "images that do not read anonymously are refused" 1 "not all published" "${T1}"
nothing_written "... and nothing is written"
STUB_RELEASES="${T0} ${T1}" STUB_LOCK_TAGS="${T0}" release "a previous lock that cannot be read is refused" 1 "whether the images changed is unknown" "${T1}"
nothing_written "... and nothing is written"

STUB_RELEASES="${T1}" STUB_BODY="Cut by hand." release "the first release gets its assets" 0 "carries its assets" "${T1}"
says "${LOG}" "release upload ${T1} --repo ybolab/mica-build-env " && ! says "${LOG}" "clobber" &&
    pass "... uploaded to the existing release, never with --clobber" || fail "... upload: $(grep 'release upload' "${LOG}")"
no_call "... and never creates a release or a tag" "release create"
says "${LOG}" "release edit ${T1} --repo ybolab/mica-build-env --notes Cut by hand." && says "${LOG}" "Images: the first release." &&
    pass "... its notes keep the body and add the images note" || fail "... notes: $(grep 'release edit' "${LOG}")"
if (cd "${UP}" && sha256sum -c --quiet SHA256SUMS) 2>/dev/null && [ "$(sed 's/^[0-9a-f]*  //' "${UP}/SHA256SUMS")" = "build-env-image.lock" ]; then
    pass "... SHA256SUMS covers build-env-image.lock"
else
    fail "... SHA256SUMS: $(cat "${UP}/SHA256SUMS" 2>/dev/null)"
fi
if cmp -s "${UP}/build-env-image.lock" "${WORK}/good.env"; then pass "... build-env-image.lock is the generated image lock, not the repository's images.env"; else fail "... build-env-image.lock: $(cat "${UP}/build-env-image.lock" 2>/dev/null)"; fi
[ ! -e "${UP}/images.env" ] && pass "... and no images.env is attached" || fail "... an images.env was attached"
[ "$(ls "${UP}" | LC_ALL=C sort | tr '\n' ' ')" = "SHA256SUMS build-env-image.lock " ] && pass "... exactly two assets: build-env-image.lock and SHA256SUMS" || fail "... assets: $(ls "${UP}" | tr '\n' ' ')"

STUB_RELEASES="${T0} ${T1}" STUB_LOCK_TAGS="${T0}" STUB_PREV_TAG="${T0}" STUB_PREV_ENV="${WORK}/good.env" release "a release after one with the same images" 0 "Images: unchanged from ${T0}." "${T1}"
sed 's/@sha256:[0-9a-f]*$/@sha256:'"$(printf other | sha256sum | cut -d' ' -f1)"'/' "${WORK}/good.env" >"${WORK}/prev-other.env"
STUB_RELEASES="${T0} ${T1}" STUB_LOCK_TAGS="${T0}" STUB_PREV_TAG="${T0}" STUB_PREV_ENV="${WORK}/prev-other.env" release "a release after one with other images" 0 "Images: changed from ${T0}. This is a breaking update" "${T1}"
says "${LOG}" "This is a breaking update: every repository must update to it." && pass "... and its notes say so" || fail "... notes: $(grep 'release edit' "${LOG}")"
T00=20251231-2359
STUB_RELEASES="${T00} ${T0} ${T1}" STUB_LOCK_TAGS="${T00}" STUB_PREV_TAG="${T00}" STUB_PREV_ENV="${WORK}/good.env" release "an earlier release without a lock is skipped for the comparison" 0 "Images: unchanged from ${T00}." "${T1}"
STUB_RELEASES="${T0} ${T1}" release "with no earlier release carrying a lock it is the first" 0 "Images: the first release." "${T1}"

echo
echo "publish-test: ${PASS_N} passed, ${FAIL_N} failed"
[ "${FAIL_N}" = 0 ]

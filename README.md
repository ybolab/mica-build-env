# mica-build-env

The build environment of Mica OS: the build-env images and `RULES.md` (the
rules every Mica repository implements in its own scripts).

**Images.** Public multi-architecture (amd64, arm64) images in
`ghcr.io/ybolab/mica-build-env`:

| Key | Image | Adds |
| --- | --- | --- |
| `IMAGE_MICA_BUILD_BASE` | base, on Debian trixie | git, file, binutils, xz, curl, wget, openssl, jq, dpkg-dev, mmdebstrap, bun |
| `IMAGE_MICA_BUILD_C` | c, on base | build-essential, cmake, pkgconf, autotools, libtool, ccache, python3 |
| `IMAGE_MICA_BUILD_GO` | go, on c | Go, cgo |
| `IMAGE_MICA_BUILD_RUST` | rust, on c | rustc, cargo, cross std and linker, clippy, rustfmt, cargo-nextest, cargo-deny, dbus-daemon |

The repository's `images.env` holds their build inputs: the Debian base
digest, toolchain versions and hashes, and version floors. An image's tag
names a hash of its inputs, so only a changed input rebuilds it.

**Releases.** A release is tagged with the UTC time it was cut, `YYYYMMDD-HHMM`
(for example `20260218-1411`), and cut by hand:

```sh
gh release create "$(date -u +%Y%m%d-%H%M)" --target <commit of main> --title "$(date -u +%Y%m%d-%H%M)" --notes ""
```

That creates the tag on GitHub and triggers `.github/workflows/release.yml`,
which builds from the tag: its images job pushes the images these inputs do not
have yet, then its assets job attaches `build-env-image.lock`, generated from the
published images (the four `IMAGE_MICA_BUILD_*` references), and `SHA256SUMS`, and adds to the notes whether
the images changed from the previous release (a change is a breaking update).
`.github/workflows/ci.yml` runs the gates below on push and pull request and
publishes nothing. A consumer pins the tag and the sha256 of `SHA256SUMS`.

```sh
bash from.sh --check                              # every IMAGE_ key is a digest pin
bash publish-images.sh --resolve --out images.out # the images this commit names, if published
bash tests/publish-test.sh                        # which inputs move which image, every release refusal
docker run --rm -v "$PWD:/repo:ro" -w /repo rhysd/actionlint:latest   # the workflows
```

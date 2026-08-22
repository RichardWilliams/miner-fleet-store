#!/usr/bin/env bash
#
# Fail when the store listing's `releaseNotes` and the upstream GitHub Release
# body for the pinned version disagree.
#
# This closes the third link of a chain whose first two already exist: upstream,
# `release-image.yml` fails a release on git-tag vs package.json drift; here,
# `check-version-drift.sh` fails on manifest vs compose drift; this gate covers
# listing vs upstream Release. The narrative an operator reads in the Umbrel UI
# is authored ONCE, in the Release, and this repo only carries a copy — so the
# copy has to be checked, or it silently becomes a second, divergent original.
#
# NO NETWORK. The comparison is against the artefact `scripts/release.sh`
# vendored at bump time under `upstream/v<version>/`, not against a live
# `gh release view`. The one networked read happens in the driver, on the
# operator's machine, where the network and `gh` exist; the push-time gate is a
# purely textual comparison against a committed copy. That is the whole of
# DECISIONS.md entry 13, and it is forced rather than merely preferred: the
# pinned CI image carries neither `gh` nor `docker` nor a guaranteed network, so
# a networked gate could only fail open or false-block.
#
# The vendored directory is named for the version it was fetched at, and this
# gate requires EXACTLY ONE directory under `upstream/` whose name matches the
# manifest's own `version`. That is what makes staleness mechanically visible
# with no network: a bump that forgets to re-vendor, or a stale copy left beside
# a new one, fails here rather than passing on the old artefact.
#
# This gate is the ONLY place the "exactly one directory" half is written. The
# sibling `check-deploy-contract.sh` derives its own contract path from the same
# pinned version, so it can never read a directory naming another version on its
# own account; what it cannot see is a SECOND, stale directory beside the pinned
# one, because it would go on reading the correct one and pass. That case is
# covered wherever either gate reads a VENDORED artefact, because both gates run
# there — `.local-ci.yml` runs both on every push and DEPLOY.md § 3.1 lists both
# in the hand-edit recovery path — not because the sibling calls into anything
# here.
#
# The pairing is not universal, and saying so is the point: `scripts/release.sh`
# step 6 runs the sibling ALONE. That invocation passes a STAGED contract by
# path, so it consults no vendored directory and has no stale sibling to miss.
#
# THE COMPARISON IS ROUND-TRIP, NOT TEXTUAL. A `>-` folded scalar is not a
# byte-preserving container, so a byte-perfect copy of the upstream body does
# not equal the manifest's raw text. This gate compares the PARSED manifest
# value against the emitted-then-parsed vendored body — one operation,
# `manifest_data.py round-trip`, shared with the driver that wrote the block.
# A raw comparison would be a false block on correct input, the mirror image of
# the false-pass defect `check-version-drift.sh`'s header records.
#
# FAIL-CLOSED, in the style of its siblings. A missing manifest, an absent
# `releaseNotes`, a `releaseNotes` that appears more than once, an unparseable
# version, a missing or empty vendored body, more than one vendored directory,
# or a vendored directory that does not name the pinned version is a FAILURE,
# never a skip. Every clause there is a case in
# tests/test-check-release-notes-drift.sh's fail-closed section, including the
# two staleness ones this gate alone carries — a second vendored directory
# beside the pinned one, and a single directory naming the wrong version — so
# the list is a description of tested behaviour rather than an intention.

set -euo pipefail

# Resolved from this script's own location, so the gate runs identically from
# the repo root, from a worktree, and from inside the CI container.
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"

# fail() is shared with the sibling gates — see scripts/lib/check-common.sh.
source "${script_dir}/lib/check-common.sh"
# The repo's GitHub coordinates and shared paths are declared once — see
# scripts/lib/repo-context.sh and INVARIANTS.md § Encapsulation.
source "${script_dir}/lib/repo-context.sh"

readonly HELPER="${script_dir}/lib/manifest_data.py"
manifest="${repo_root}/${MANIFEST_REL_PATH}"
vendor_root="${repo_root}/${VENDOR_REL_DIR}"

# Guard order: the interpreter this gate cannot work without, then the files it
# reads. A missing python3 diagnosed here beats a parse error further down.
command -v python3 >/dev/null 2>&1 \
  || fail "python3 not found on PATH; this gate parses YAML with it because the pinned CI image ships no jq and no yq"
[[ -f "$HELPER" ]] || fail "shared manifest parser not found at ${HELPER}"
[[ -f "$manifest" ]] || fail "app manifest not found at ${manifest}"
[[ -d "$vendor_root" ]] || fail "vendored upstream directory not found at ${vendor_root} — scripts/release.sh writes it at bump time"

# The pinned version decides which vendored directory is the right one, so it is
# read and shape-checked before anything is resolved against it.
version="$(python3 "$HELPER" get "$manifest" version 2>&1)" || fail "$version"
[[ "$version" =~ ^${SEMVER_ERE}$ ]] \
  || fail "manifest version '${version}' is not a semver, so no vendored directory name can be derived from it"

# Exactly one vendored directory, named for the pinned version. A glob rather
# than `find -printf`, which is a GNU extension.
shopt -s nullglob
vendored_dirs=()
for entry in "${vendor_root}"/*/; do
  vendored_dirs+=("$(basename "$entry")")
done
shopt -u nullglob

if (( ${#vendored_dirs[@]} == 0 )); then
  fail "no vendored upstream directory under ${VENDOR_REL_DIR}/ — expected $(vendor_rel_path "$version")/, written by scripts/release.sh"
fi
if (( ${#vendored_dirs[@]} > 1 )); then
  fail "${#vendored_dirs[@]} directories under ${VENDOR_REL_DIR}/ (${vendored_dirs[*]}) — expected exactly one; a stale copy beside a current one could satisfy this gate against the wrong release"
fi
if [[ "${vendored_dirs[0]}" != "$(vendor_dir_name "$version")" ]]; then
  fail "vendored directory is ${VENDOR_REL_DIR}/${vendored_dirs[0]}/ but the manifest pins ${version} — re-run scripts/release.sh ${version} so the vendored artefacts match the pin"
fi

notes="${repo_root}/$(vendor_rel_path "$version" "$VENDOR_NOTES_NAME")"
[[ -f "$notes" ]] || fail "vendored release body not found at ${notes}"
[[ -s "$notes" ]] || fail "vendored release body at ${notes} is empty — an empty upstream Release body is a hard failure, not an empty listing"

# The two sides of the comparison. `expected` is the vendored body emitted as a
# folded scalar and parsed straight back; `declared` is what the manifest
# actually carries. Both go through the same parser, so the only difference
# either can show is a real one.
expected="$(python3 "$HELPER" round-trip "$notes" "$NOTES_BLOCK_INDENT" 2>&1)" || fail "$expected"
declared="$(python3 "$HELPER" get "$manifest" releaseNotes 2>&1)" || fail "$declared"

if [[ "$declared" != "$expected" ]]; then
  fail "release-notes drift: ${MANIFEST_REL_PATH} declares releaseNotes as:
${declared}

but the upstream Release body vendored at $(vendor_rel_path "$version" "$VENDOR_NOTES_NAME") round-trips to:
${expected}

The listing is a copy of the Release, never a second original — re-run scripts/release.sh ${version} rather than editing the manifest by hand."
fi

printf 'check-release-notes-drift: OK: listing releaseNotes matches the vendored %s Release body for v%s\n' \
  "$UPSTREAM_REPO_SLUG" "$version"

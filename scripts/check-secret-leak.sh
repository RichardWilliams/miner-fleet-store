#!/usr/bin/env bash
#
# Fail when any file a release bump writes carries something shaped like a
# credential.
#
# WHY A GATE AND NOT ONLY THE DRIVER. `scripts/release.sh` refuses a credential
# in either fetched artefact before it writes a byte, which is the right place
# for the automated path. It is not the whole path. The driver is where upstream
# text ENTERS the tree; the PUSH is where it becomes PUBLIC, and those are
# different events with different ways in:
#
#   * A hand edit reaches the same end state without the driver. DEPLOY.md § 3.1
#     documents that route as the supported recovery for a machine with no
#     `docker` or no authenticated `gh`, so it is a path this repo expects to be
#     taken. `check-release-notes-drift.sh` does not close it: that gate compares
#     the listing against the VENDORED body, so an edit touching both the
#     manifest and the vendored copy satisfies it and never meets the driver's
#     refusal at all.
#   * A credential could also arrive with the vendored contract, whose
#     `documentation.*` fields are free prose, in a version bump cut before this
#     check existed.
#
# So the control is in BOTH places, over ONE definition of the shapes
# (`scripts/lib/secret-patterns.sh`, INVARIANTS.md § Encapsulation). They are not
# two spellings of one check: the driver's runs on staged copies so a refusal
# leaves the tree untouched, and this one runs on the committed tree so no route
# into it is exempt. DECISIONS.md entry 15 records the placement.
#
# SCOPE — the files a release bump writes, and only those. That is the app
# manifest, the compose file, and everything vendored under `upstream/`: the
# exact set `scripts/release.sh` rewrites, and the exact set that carries text
# copied in from the upstream repo or shipped to the operator's box. The set is
# derived from `scripts/lib/repo-context.sh` rather than listed here, so it
# cannot drift from what the driver writes.
#
# NO NETWORK, like its siblings: this reads committed files and nothing else.
#
# FAIL-CLOSED. A missing manifest, a missing compose, an absent vendored
# directory, a vendored directory with no files in it, and a file this check
# cannot read are all FAILURES, never a skip. A scan that quietly covered
# nothing would be worse than no scan, because it would look like coverage.
#
# THE FAILURE NAMES THE CATEGORY AND NEVER THE MATCH. Printing the matched text
# would disclose the credential again, into the terminal and into the CI log of
# the run that blocked it. See scripts/lib/secret-patterns.sh.

set -euo pipefail

# Resolved from this script's own location, so the gate behaves identically from
# the repo root, from a worktree, and from inside the CI container.
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"

# Three shared libraries, each with one definition for the whole repo: fail() in
# check-common.sh, the paths in repo-context.sh, and the credential shapes plus
# the scan itself in secret-patterns.sh (INVARIANTS.md § Encapsulation).
source "${script_dir}/lib/check-common.sh"
source "${script_dir}/lib/repo-context.sh"
source "${script_dir}/lib/secret-patterns.sh"

manifest="${repo_root}/${MANIFEST_REL_PATH}"
compose="${repo_root}/${COMPOSE_REL_PATH}"
vendor_root="${repo_root}/${VENDOR_REL_DIR}"

[[ -f "$manifest" ]] || fail "app manifest not found at ${manifest}"
[[ -f "$compose" ]] || fail "compose file not found at ${compose}"
[[ -d "$vendor_root" ]] || fail "vendored upstream directory not found at ${vendor_root} — scripts/release.sh writes it at bump time, and a scan with nothing to read is not a scan that passed"

# The two rewritten files first, then everything vendored. `globstar` rather
# than `find`, so a path carrying a space or a newline stays one array element
# and the list this gate reports is exactly the list it scanned.
#
# The walk is RECURSIVE and takes every regular file it finds, not just the two
# artefacts the driver writes. A gate that scanned only the filenames it expected
# would clear a `upstream/notes-old.txt` left behind by hand, which is precisely
# the route this gate exists to cover.
targets=("$manifest" "$compose")

shopt -s nullglob globstar
for vendored in "${vendor_root}"/**; do
  if [[ -f "$vendored" ]]; then
    targets+=("$vendored")
  fi
done
shopt -u nullglob globstar

if (( ${#targets[@]} == 2 )); then
  fail "no vendored files under ${VENDOR_REL_DIR}/ — expected the release-notes body and the deployment contract written by scripts/release.sh. An empty vendored tree would let this gate report a clean scan of nothing."
fi

# --- the scan ----------------------------------------------------------------

category=""
for target in "${targets[@]}"; do
  if ! secret_scan_file category "$target"; then
    fail "${target#"${repo_root}/"} contains ${category}. ${SECRET_LEAK_RATIONALE} Remove it from the upstream Release body or the upstream deployment contract, publish the corrected artefact, and re-run scripts/release.sh so the vendored copy and the listing are rewritten from it."
  fi
done

printf 'check-secret-leak: OK: no credential shape in the %d files a release bump writes\n' \
  "${#targets[@]}"

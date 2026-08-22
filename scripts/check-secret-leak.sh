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
# directory, a vendored directory with no files in it, a file this check cannot
# read, a directory it cannot list, and any vendored entry that is not a regular
# file are all FAILURES, never a skip. A scan that quietly covered nothing would
# be worse than no scan, because it would look like coverage. The walk below
# states which entry takes which branch; that list and this one are the same
# promise written twice, once as prose and once as code.
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
# and the list this gate reports is exactly the list it scanned. `dotglob`
# beside it, and that one is load-bearing rather than tidy: bash's `**` matches
# no path component beginning with a dot, so without it a `.leftover-notes.txt`
# sitting next to the two artefacts — or a whole hidden directory of them — was
# enumerated by nothing, counted by nothing, and cleared by a run whose OK line
# read exactly like a clean tree's. The two-artefact backstop below does not
# reach it either: that trips only when the vendored tree holds NOTHING but
# hidden entries, so one dotfile beside the artefacts the driver always writes
# left it satisfied.
#
# WHAT THIS WALK COVERS, stated as what the loop does rather than as a claim of
# completeness. It visits every entry at every depth beneath the vendored root,
# dot-prefixed or not, and each one takes exactly one of three branches: a plain
# directory it descends, a regular file it scans, or ANYTHING ELSE, which stops
# the run. There is no fourth branch and nothing is passed over quietly.
#
# WHICH TESTS MAKE THAT TRUE. The sentence above is a universal claim about a
# loop, so the cases that hold it up are named rather than assumed — this exact
# claim was false once (the walk skipped dot-prefixed entries until dotglob was
# added), and a reader has no way to tell a swept claim from an unswept one
# unless it says where it is checked. In tests/test-check-secret-leak.sh:
# "a credential in a hidden file beside the artefacts fails", "the refusal names
# the hidden file it was in", "a credential inside a hidden directory fails" and
# "a clean hidden file is counted, not silently passed over" hold the
# dot-prefixed half at both depths; "a directory the walk cannot list fails" and
# "a symlink under the vendored root fails" hold two of the three branches; the
# fifo case holds the third.
#
# It is RECURSIVE and takes every regular file rather than the two filenames the
# driver writes, because a gate that scanned only the names it expected would
# clear an `upstream/notes-old.txt` left behind by hand — precisely the route
# this gate exists to cover.
#
# The third branch is the one worth explaining, because "refuse it" rather than
# "skip it" is what keeps the first sentence true. `scripts/release.sh` writes
# regular files into plain directories and nothing else, so every other kind of
# entry here arrived by hand, and this gate has no way to read one and therefore
# no way to clear one:
#
#   * A SYMLINK is refused rather than followed. What git publishes for a
#     symlink is its target PATH — scanning the target's CONTENTS instead would
#     be reading a different thing from the one that becomes public, and a
#     symlink pointing outside the tree, or at nothing, is not readable as a
#     vendored artefact at all.
#   * A DIRECTORY bash cannot list is refused. A glob over an unreadable
#     directory yields nothing and reports nothing, so the alternative is a
#     silent skip of every file inside it — the same shape as the dotfile gap
#     above.
#   * Anything that is neither (a fifo, a socket, a device node) is refused for
#     the same reason: `grep` over it does not answer the question this gate
#     asks, and git cannot carry it into a release anyway.
targets=("$manifest" "$compose")

shopt -s nullglob globstar dotglob
for vendored in "${vendor_root}"/**; do
  # `-L` first: `-d` and `-f` both follow a symlink, so either would take a
  # symlinked entry down the wrong branch.
  if [[ -L "$vendored" ]]; then
    fail "${vendored#"${repo_root}/"} is a symlink. Everything under ${VENDOR_REL_DIR}/ is written by scripts/release.sh as a regular file; what git would publish for a symlink is its target path rather than the bytes this gate can scan, so it is refused instead of followed. Replace it with the artefact itself."
  elif [[ -d "$vendored" ]]; then
    [[ -r "$vendored" && -x "$vendored" ]] || fail "${vendored#"${repo_root}/"} is a directory this check cannot list, so every file inside it would be skipped without appearing in the count below. A scan that quietly covered nothing is not a scan that passed. Restore read and execute permission on it and re-run."
  elif [[ -f "$vendored" ]]; then
    targets+=("$vendored")
  else
    fail "${vendored#"${repo_root}/"} is neither a regular file nor a directory. Only the regular files scripts/release.sh vendors belong under ${VENDOR_REL_DIR}/, and this check has no way to read anything else and therefore no way to clear it. Remove it and re-run."
  fi
done
shopt -u nullglob globstar dotglob

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

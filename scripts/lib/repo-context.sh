#!/usr/bin/env bash
#
# The one declaration of this repo's GitHub coordinates, of the file paths the
# release driver and its gates share, and of the patterns derived from them.
#
# INVARIANTS.md § Encapsulation states the rule this file exists to satisfy: a
# managed repo's own tracked code declares its `owner/repo` slug exactly ONCE,
# at the fixed conventional path `scripts/lib/repo-context.sh`, and every
# consumer sources it. The path is FIXED rather than merely named so the
# invariant judge — whose prompt is diff-scoped — can decide from the diff alone
# whether a second declaration was introduced: any other file naming an
# `owner/repo` slug is a violation on its own, with no need to see this file's
# content in the same push.
#
# The coordinates are declared as constants rather than derived from a git
# remote at run time. Deriving them would mean either re-implementing the
# codespace's own remote-URL parsing (banned as a duplicate) or calling
# `scripts/lib/git-slug.sh`, which is tracked in the codespace repo alone and is
# therefore unreachable from a store script that runs on the operator's machine.
#
# SOURCE this file, never execute it — mode 644, the same convention as
# scripts/lib/check-common.sh and tests/lib/bash-test-harness.sh.
#
# Assignments are plain rather than `readonly` so a consumer that sources this
# file more than once in a single shell (a test suite driving several fixtures,
# for example) does not abort on a re-assignment to a read-only name.

# --- GitHub coordinates ------------------------------------------------------

# This repo. Consumed when opening or looking up the release PR.
STORE_REPO_SLUG="RichardWilliams/miner-fleet-store"

# The repo that owns the application, its published image, its GitHub Releases
# and its deployment contract. This store asserts against those artefacts; it
# never writes to that repo.
UPSTREAM_REPO_SLUG="RichardWilliams/miner-fleet"

# The path, inside the upstream repo, of the generated deployment contract the
# release driver fetches at the pinned tag.
UPSTREAM_CONTRACT_PATH="deploy/contract.json"

# --- Registry coordinate -----------------------------------------------------

# The published image, without a tag or digest. The release driver asks the
# registry itself for the index digest of `${UPSTREAM_IMAGE}:X.Y.Z`; nothing is
# hand-carried between the two repos.
UPSTREAM_IMAGE="ghcr.io/richardwilliams/miner-fleet"

# --- In-repo paths -----------------------------------------------------------

# The Umbrel app id, which is also the app directory name (DECISIONS.md entry 1).
APP_ID="pipfox-miner-fleet"

# Repo-relative paths of the two files a release bump rewrites.
MANIFEST_REL_PATH="${APP_ID}/umbrel-app.yml"
COMPOSE_REL_PATH="${APP_ID}/docker-compose.yml"

# Repo-relative root of the vendored upstream artefacts. Deliberately OUTSIDE
# the app directory: `${APP_ID}/` is the template umbreld rsyncs onto the
# operator's box, and provenance artefacts have no business shipping there
# (DECISIONS.md entry 13).
VENDOR_REL_DIR="upstream"

# The two filenames inside the vendored artefact directory.
VENDOR_CONTRACT_NAME="contract.json"
VENDOR_NOTES_NAME="release-notes.txt"

# vendor_dir_name <version> — the NAME of the vendored artefact directory for
# <version>.
#
# This is the staleness guard itself, not a spelling convenience. Nothing
# records which release the vendored artefacts were fetched at except the name
# of the directory they sit in, so check-release-notes-drift.sh decides
# staleness by comparing the ONE directory it finds against the name this
# function returns for the version the manifest pins. A second spelling of the
# name anywhere — at the writer, at a reader, or at the comparison — lets the
# two sides disagree and the guard then passes against the wrong artefacts,
# silently, which is exactly what the version-encoded name exists to make loud
# (INVARIANTS.md § Encapsulation).
#
# NOT the upstream git tag, which happens to be spelled `v<version>` too. That
# tag is miner-fleet's naming of its own releases, read over the network by the
# driver; this is THIS repo's naming of a directory in its own tree. They
# coincide today and are free to stop coinciding, so the driver's
# `gh release view v${version}` and `?ref=v${version}` are deliberately NOT
# routed through here, and tests/test-release.sh's fail-closed `gh` stub pins
# that separation by refusing any other tag.
vendor_dir_name() {
  printf 'v%s' "$1"
}

# vendor_rel_path <version> [<name>...] — the repo-relative path of the
# vendored artefact directory for <version>, or of a named file inside it.
#
# The consumers want three different things from this one join — an absolute
# directory to write into, an absolute file path to read, and the repo-relative
# label a diagnostic prints — and all three are this string, with the repo root
# prefixed or not. Returning the repo-relative form is what lets a diagnostic
# use it directly, and `${repo_root}/$(vendor_rel_path …)` is the same
# convention `${repo_root}/${COMPOSE_REL_PATH}` already follows.
vendor_rel_path() {
  local version="$1"
  shift
  local path=""
  path="${VENDOR_REL_DIR}/$(vendor_dir_name "$version")"
  local component=""
  for component in "$@"; do
    path="${path}/${component}"
  done
  printf '%s' "$path"
}

# The block indent of the `releaseNotes:` folded scalar in the app manifest. The
# emitter and the drift gate both read it from here, so the value the driver
# writes and the value the gate re-emits can never disagree.
NOTES_BLOCK_INDENT=2

# --- when a consumer may retype a value instead of sourcing this file --------
#
# Every production consumer sources this file. The test suites are the one place
# a value is legitimately RETYPED, and only under one condition, stated here so a
# future reader can check it rather than infer it from which literals happen to
# be present:
#
#   A test may retype a coordinate ONLY when a change to the declaration above
#   makes that test FAIL LOUDLY. It may never retype one where a change above
#   leaves the test green while it exercises the stale value.
#
# What decides it is what the fixture does with the value. Each suite's
# `make_fixture()` COPIES this file into the fixture and runs the real script
# against it, so a retyped PATH coordinate desyncs the tree the fixture builds
# from the path the copied library tells the script to read: the script looks in
# the new place, finds nothing, and the suite goes red. That covers `APP_ID` and
# the `upstream` directory name in the suites that still spell them out, the
# `v<version>` fixture directory names those suites build the vendored artefacts
# under, the four `umbrel-app.yml` / `docker-compose.yml` /
# `release-notes.txt` / `contract.json` filenames, the image coordinate that
# `COMPOSE_IMAGE_ERE` is built from, and the contract path the release-driver
# suite's fail-closed `gh` stub refuses any other value for.
#
# The `v<version>` names carry a second obligation the others do not, because
# `vendor_dir_name` above is compared against a directory found on disk as well
# as used to build paths: a re-inlined join at ONE of those sites would leave
# every fixture that spells the name the way this file currently does still
# green. So the three suites that exercise the derivation each carry a case
# that REDECLARES `vendor_dir_name` in the fixture's own copy of this file and
# requires the script to follow it end to end. A second spelling at any site
# stops following, and that case goes red. The one name that needs no agreement
# is the release suite's PREVIOUS-version directory: the driver removes every
# directory it finds under the vendored root whatever it is called, so that
# fixture name stands for "some leftover directory" rather than for this
# coordinate.
#
# `NOTES_BLOCK_INDENT` is the one the condition above does not decide either
# way, and saying why is the point of naming it here — a reader who assumed the
# rule reached it would be assuming a guard that does not exist. A retyped
# indent would leave the suite green, but so would a divergent one in
# production, because nothing in this repo can tell the two apart: `emit_block()`
# pads every body line uniformly, a folded scalar's block indent is taken from
# its own content and is not part of the value a parser returns, and every
# consumer here compares PARSED values — through `round_trip()` or a `get` —
# never raw bytes. `round_trip(body, 2)` and `round_trip(body, 4)` therefore
# return the same string by construction. That indent-stripping is a property of
# the YAML block-scalar form itself rather than of the parser this repo happens
# to use, so a reader of the shipped manifest sees the same value too.
#
# So routing every site through this one declaration is a single-source-of-truth
# measure and nothing more: one value, read by the driver, by the drift gate, by
# both test suites that emit a `releaseNotes` block, and by DEPLOY.md § 3.1's
# hand-edit step, which sources this file two steps earlier — so no site has to
# be kept in agreement with any other by hand. It is NOT a tested regression
# guard, and it is not written up as one: a test asserting the on-disk padding
# would pin a property that has no consequence anywhere, which is a test written
# for the sake of having one.

# --- Shared patterns ---------------------------------------------------------

# The shape of a release version, X.Y.Z, as a POSIX ERE — no \d, \s or \b
# (INVARIANTS.md § Tool invocation correctness). Deliberately unanchored: each
# consumer anchors it for its own use. The release driver validates its
# argument with it, check-version-drift matches the manifest `version:` line and
# the compose image tag, and the two contract gates shape-check the version they
# read before deriving a vendored directory name from it.
SEMVER_ERE='[0-9]+\.[0-9]+\.[0-9]+'

# ere_escape <value> — print <value> with every POSIX ERE metacharacter
# backslash-escaped, so the result is a pattern that matches that value
# literally.
#
# A pattern hand-spelled beside the value it is meant to match is a second copy
# of that value in a different alphabet, free to drift from it. Deriving the
# pattern FROM the value removes the second copy: change the coordinate and
# every pattern built from it moves with it. The derivation is itself a derived
# value, so it lives here once rather than being repeated at each consumer
# (INVARIANTS.md § Encapsulation).
#
# The metacharacter set is the POSIX ERE special set. `/` and `-` are not
# special outside a bracket expression and are therefore left alone.
ere_escape() {
  local value="$1"
  local metacharacters='.[]\()*+?{}|^$'
  local escaped="" char=""
  local position=0
  for (( position = 0; position < ${#value}; position++ )); do
    char="${value:position:1}"
    if [[ "$metacharacters" == *"$char"* ]]; then
      escaped+="\\"
    fi
    escaped+="$char"
  done
  printf '%s' "$escaped"
}

# The published image name as a POSIX ERE matching that name literally.
UPSTREAM_IMAGE_ERE="$(ere_escape "$UPSTREAM_IMAGE")"

# The shape of an image digest reference — sha256 and its 64 lowercase hex
# characters. The release driver reads one out of the registry's top-level
# `Digest:` line; the pinned `image:` pattern below requires one.
DIGEST_ERE='sha256:[0-9a-f]{64}'

# What may legitimately follow a value on the YAML lines this repo parses:
# optional whitespace, an optional `# comment`, then end of line. A trailing
# comment is valid YAML and is written in practice — the compose file's own
# style puts prose about digests beside the pin, and DEPLOY.md's roll-back
# guidance invites recording the previous tag there — so a pattern that refused
# one would block a correct release edit.
TRAILING_ERE='[[:space:]]*(#.*)?$'

# The pinned `image:` line of the compose file, as a whole-line POSIX ERE.
#
# The release driver rewrites the line this matches; check-version-drift reads
# the release tag out of it. Both anchor on THIS string, so the reference the
# driver emits is by construction the reference the gate accepts — there is no
# writer spelling and reader spelling left to drift apart (INVARIANTS.md
# § Encapsulation).
#
# Capture groups, in the order a match yields them:
#   \1  through to the end of the image name — the part a rewrite keeps, with a
#       fresh `:tag@digest` appended to it
#   \2  the release tag
#   \3  everything that trailed the digest, re-emitted verbatim by a rewrite so
#       a comment beside the pin survives it
#
# TRAILING_ERE carries a `(#…)` group of its own, so \3 has a nested \4. No
# consumer needs it; it is named here only so the numbering above is unambiguous.
COMPOSE_IMAGE_ERE="^([[:space:]]+image:[[:space:]]+${UPSTREAM_IMAGE_ERE}):(${SEMVER_ERE})@${DIGEST_ERE}(${TRAILING_ERE})"

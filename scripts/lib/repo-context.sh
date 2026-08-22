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

# The two filenames inside `upstream/v<version>/`.
VENDOR_CONTRACT_NAME="contract.json"
VENDOR_NOTES_NAME="release-notes.txt"

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
# four `umbrel-app.yml` / `docker-compose.yml` / `release-notes.txt` /
# `contract.json` filenames, the image coordinate that `COMPOSE_IMAGE_ERE` is
# built from, and the contract path the release-driver suite's fail-closed `gh`
# stub refuses any other value for.
#
# `NOTES_BLOCK_INDENT` is the one that is NOT that case, which is why this block
# exists. A manifest emitted at a stale indent is still valid YAML, so a retyped
# indent leaves the suite green while exercising an indent production code has
# moved off — it fails OPEN. Every consumer of it reads it from here: both test
# suites that emit a `releaseNotes` block, and DEPLOY.md § 3.1's hand-edit step,
# which sources this file two steps earlier.

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

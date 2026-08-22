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

# The published image name as a POSIX ERE matching that name literally. Consumed
# by the release driver, which rewrites the pinned `image:` line, and by
# check-version-drift, which reads the tag out of it.
UPSTREAM_IMAGE_ERE="$(ere_escape "$UPSTREAM_IMAGE")"

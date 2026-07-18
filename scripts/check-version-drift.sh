#!/usr/bin/env bash
#
# Fail when the app manifest's `version` and the compose file's image tag
# disagree.
#
# The two values are independent hand-edited copies of the same release number.
# `umbrel-app.yml`'s `version` is what Umbrel DISPLAYS and what decides whether
# an Update button appears; `docker-compose.yml`'s `image:` tag is part of what
# actually RUNS. Nothing structural ties them together — umbreld does not
# substitute the manifest version into the compose file — so a release PR can
# ship a store where Umbrel shows 0.2.0 and the box runs 0.1.0, silently and
# indefinitely. This check is the mechanical link.
#
# It is the store-side counterpart of the equivalent invariant miner-fleet
# already enforces upstream: `release-image.yml` fails a release when the git
# tag and `package.json`'s version disagree (miner-fleet DECISIONS.md entry 6).
# That gate covers tag-vs-source; this one covers manifest-vs-compose. Together
# they close the chain from git tag through published image to what Umbrel
# displays.
#
# FAIL-CLOSED. A file that is missing, a field that is absent, a field that
# appears more than once, or a value that does not match the expected shape is a
# FAILURE, never a skip. A check that silently passes when it cannot read its
# inputs is worse than no check: it reports safety it never established.
#
# Scope: textual consistency only. It does NOT contact the registry to confirm
# the pinned digest resolves. A network call inside a push-time gate fails when
# the network or ghcr is unavailable, which is a false block on work that is
# actually fine. Confirming the published artefact is a release-time step and
# lives in DEPLOY.md § 3.

set -euo pipefail

# Resolve the repo root from this script's own location so the check runs
# correctly from any working directory, in the container and on the host alike.
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"

readonly APP_ID="pipfox-miner-fleet"
manifest="${repo_root}/${APP_ID}/umbrel-app.yml"
compose="${repo_root}/${APP_ID}/docker-compose.yml"

fail() {
  printf 'check-version-drift: FAIL: %s\n' "$1" >&2
  exit 1
}

# Guard order: required files before any parsing, so a missing file produces a
# clear diagnostic rather than an empty-match error further down.
[[ -f "$manifest" ]] || fail "app manifest not found at ${manifest}"
[[ -f "$compose" ]] || fail "compose file not found at ${compose}"

# POSIX ERE only — `grep -E` does not implement \d, \s or \b (INVARIANTS.md
# § Tool invocation correctness). Anchored at line start so a `version:` nested
# inside another block cannot match.
#
# The patterns accept every YAML spelling that is LEGITIMATE for these two
# fields, because a gate that blocks a valid release edit is as much a defect as
# one that misses a real drift — it just fails in the direction that looks safe.
# Accepted variants: double-quoted, single-quoted, and unquoted values (all three
# are valid YAML here; the quoting exists to stop YAML reading a two-component
# version as a float, so an author may reasonably use either quote style), and a
# trailing `# comment` on either line.
#
# The image name is duplicated in pipfox-miner-fleet/docker-compose.yml. Both
# sites must move together if the app is ever republished under a different
# name; this check fails closed on a mismatch rather than passing silently, so a
# half-done rename surfaces here rather than on the operator's box.
readonly SEMVER_ERE='[0-9]+\.[0-9]+\.[0-9]+'
readonly TRAILING_ERE='[[:space:]]*(#.*)?$'
readonly MANIFEST_VERSION_ERE="^version:[[:space:]]+['\"]?${SEMVER_ERE}['\"]?${TRAILING_ERE}"
readonly COMPOSE_IMAGE_ERE="^[[:space:]]+image:[[:space:]]+ghcr\.io/richardwilliams/miner-fleet:${SEMVER_ERE}@sha256:[0-9a-f]{64}${TRAILING_ERE}"

# A field appearing twice is ambiguous — the check cannot know which copy is
# authoritative, and picking one would be a guess. Both zero matches and more
# than one are failures.
require_exactly_one() {
  local count="$1" what="$2" file="$3"
  if (( count == 0 )); then
    fail "no ${what} found in ${file} — the field is absent or malformed"
  fi
  if (( count > 1 )); then
    fail "${count} ${what} lines found in ${file} — expected exactly one; cannot determine which is authoritative"
  fi
}

manifest_matches="$(grep -cE "$MANIFEST_VERSION_ERE" "$manifest" || true)"
require_exactly_one "$manifest_matches" "well-formed 'version:' line" "$manifest"

compose_matches="$(grep -cE "$COMPOSE_IMAGE_ERE" "$compose" || true)"
require_exactly_one "$compose_matches" "well-formed pinned 'image:' line" "$compose"

# Strip in order: the key, any trailing comment, surrounding quotes of either
# style, then trailing whitespace. The compose extraction needs no comment strip
# because `@sha256:.*$` already consumes anything after the digest.
manifest_version="$(grep -E "$MANIFEST_VERSION_ERE" "$manifest" \
  | sed -E "s/^version:[[:space:]]+//; s/[[:space:]]*#.*$//; s/^['\"]//; s/['\"]$//; s/[[:space:]]*$//")"
compose_version="$(grep -E "$COMPOSE_IMAGE_ERE" "$compose" | sed -E 's|^.*/miner-fleet:||; s|@sha256:.*$||')"

# Belt-and-braces: the extraction must itself produce a semver. If a future edit
# to the patterns above lets something else through, this fails rather than
# comparing two empty strings and reporting success.
[[ "$manifest_version" =~ ^${SEMVER_ERE}$ ]] || fail "extracted manifest version '${manifest_version}' is not a semver"
[[ "$compose_version" =~ ^${SEMVER_ERE}$ ]] || fail "extracted compose image tag '${compose_version}' is not a semver"

if [[ "$manifest_version" != "$compose_version" ]]; then
  fail "version drift: ${APP_ID}/umbrel-app.yml declares '${manifest_version}' but ${APP_ID}/docker-compose.yml pins image tag '${compose_version}'. Umbrel would display ${manifest_version} while running ${compose_version}. Both move together — see DEPLOY.md § 3."
fi

printf 'check-version-drift: OK: manifest and compose agree on %s\n' "$manifest_version"

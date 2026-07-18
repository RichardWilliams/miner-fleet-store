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
readonly IMAGE_NAME_ERE='ghcr\.io/richardwilliams/miner-fleet'
# Quote handling is an alternation of three whole forms, NOT two independently
# optional quote classes. `['\"]?VALUE['\"]?` would accept a MISMATCHED pair
# (`version: '0.1.0"`), which is not valid YAML, and passing it as "well-formed"
# contradicts this script's own fail-closed contract. POSIX ERE has no
# backreference to require the closing quote match the opening one, so the three
# legal spellings are enumerated instead.
readonly QUOTED_SEMVER_ERE="(\"${SEMVER_ERE}\"|'${SEMVER_ERE}'|${SEMVER_ERE})"
readonly MANIFEST_VERSION_ERE="^version:[[:space:]]+${QUOTED_SEMVER_ERE}${TRAILING_ERE}"
readonly COMPOSE_IMAGE_ERE="^[[:space:]]+image:[[:space:]]+${IMAGE_NAME_ERE}:${SEMVER_ERE}@sha256:[0-9a-f]{64}${TRAILING_ERE}"

# A field appearing twice is ambiguous — the check cannot know which copy is
# authoritative, and picking one would be a guess. Both zero matches and more
# than one are failures.
require_exactly_one() {
  local count="$1" what="$2" file="$3"
  if (( count == 0 )); then
    fail "no ${what} found in ${file} — the field is absent or malformed"
  fi
  if (( count > 1 )); then
    fail "${count} ${what}s found in ${file} — expected exactly one; cannot determine which is authoritative"
  fi
}

manifest_matches="$(grep -cE "$MANIFEST_VERSION_ERE" "$manifest" || true)"
require_exactly_one "$manifest_matches" "well-formed 'version:' line" "$manifest"

compose_matches="$(grep -cE "$COMPOSE_IMAGE_ERE" "$compose" || true)"
require_exactly_one "$compose_matches" "well-formed pinned 'image:' line" "$compose"

# BOTH extractions anchor at `^` on the SAME structural prefix their grep
# pattern matched. Neither may use a bare `.*` search for a substring that can
# appear anywhere in the line.
#
# This is load-bearing, not style. The compose strip was previously
# `s|^.*/miner-fleet:||` — an unanchored greedy prefix. Once trailing comments
# became legal input, a comment containing a second `/miner-fleet:X.Y.Z`-shaped
# token made sed strip through the LAST occurrence rather than the one grep
# anchored on, so the version was read out of the COMMENT instead of the real
# pin. That produced a false PASS on genuine drift — the exact failure this
# check exists to catch — and, in the mirror case, a false BLOCK on a correct
# release. Comments next to this line are not hypothetical: the compose file's
# own style writes prose about digests there, and DEPLOY.md's roll-back guidance
# invites recording the previous tag beside it.
manifest_version="$(grep -E "$MANIFEST_VERSION_ERE" "$manifest" \
  | sed -E "s/^version:[[:space:]]+//; s/[[:space:]]*#.*$//; s/^['\"]//; s/['\"]$//; s/[[:space:]]*$//")"
compose_version="$(grep -E "$COMPOSE_IMAGE_ERE" "$compose" \
  | sed -E "s|^[[:space:]]+image:[[:space:]]+${IMAGE_NAME_ERE}:||; s|@sha256:.*$||")"

# Belt-and-braces: the extraction must itself produce a semver. If a future edit
# to the patterns above lets something else through, this fails rather than
# comparing two empty strings and reporting success.
[[ "$manifest_version" =~ ^${SEMVER_ERE}$ ]] || fail "extracted manifest version '${manifest_version}' is not a semver"
[[ "$compose_version" =~ ^${SEMVER_ERE}$ ]] || fail "extracted compose image tag '${compose_version}' is not a semver"

if [[ "$manifest_version" != "$compose_version" ]]; then
  fail "version drift: ${APP_ID}/umbrel-app.yml declares '${manifest_version}' but ${APP_ID}/docker-compose.yml pins image tag '${compose_version}'. Umbrel would display ${manifest_version} while running ${compose_version}. Both move together — see DEPLOY.md § 3."
fi

printf 'check-version-drift: OK: manifest and compose agree on %s\n' "$manifest_version"

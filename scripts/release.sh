#!/usr/bin/env bash
#
# Cut a store release for miner-fleet X.Y.Z.
#
# A release starts in miner-fleet, not here. Once that repo has published the
# image and the GitHub Release, THIS script is the whole store-side procedure:
# it resolves the digest from the registry, fetches the Release body and the
# deployment contract, asserts the contract against the current compose, and
# only then rewrites the pinned version, the image reference and the listing's
# release notes, and opens the PR. DEPLOY.md § 3 keeps the equivalent hand-edit
# as the recovery path for when this script cannot run.
#
# WHAT IT NEVER DOES.
#
#   * It never accepts a digest as an argument, and never reads one from a file
#     the upstream repo produced. It asks the registry itself for the multi-arch
#     INDEX digest — the top-level `Digest:` line, never one of the indented
#     per-platform entries under `Manifests:` (DECISIONS.md entry 4). That is
#     what keeps the two repos' release scripts independent: this one can be run
#     hours later, from another machine, with nothing carried between them.
#   * It never falls through to hand-written release notes. A missing Release,
#     an empty body, or a `gh` failure is a hard failure (DECISIONS.md entry 10).
#   * It never copies a credential out of the private upstream repo into this
#     public one. Both fetched artefacts are checked against the credential
#     shapes in `scripts/lib/secret-patterns.sh` while they are still staged,
#     and a match stops the run naming the CATEGORY and never the matched text
#     (DECISIONS.md entry 15).
#   * It never writes a byte into the tree before the deployment contract has
#     been asserted against the compose that is already there, so a mismatch
#     leaves the working tree exactly as it was.
#
# VENDOR-AT-BUMP-TIME. The two networked reads — the Release body and the
# deployment contract at tag `vX.Y.Z` — happen HERE, once, on the operator's
# machine where `gh`, `docker` and the network exist. Both artefacts are then
# committed under `upstream/vX.Y.Z/`, and the two push-time gates that check
# them are purely textual comparisons against those committed copies. The
# version-encoded directory name is the staleness guard: a bump that forgets to
# re-vendor, or a stale copy left beside a current one, fails the gates. See
# DECISIONS.md entry 13 for the single policy and for what it does and does not
# buy.
#
# RESUMABLE. Re-running for the same version after a mid-sequence failure
# rewrites the same files with the same content, pushes the same branch, and
# looks for an already-open PR for that head branch rather than opening a
# second one.
#
# usage: scripts/release.sh X.Y.Z
#
# Environment: RELEASE_REMOTE overrides the git remote the release branch is
# pushed to; with it unset the first configured remote is used. Neither the
# remote name nor the default branch is hardcoded.

set -euo pipefail

# This script's own location anchors the repo root, so it behaves the same from
# the repo root, from a worktree, or from an absolute path.
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"

# fail() is shared with this repo's gates — see scripts/lib/check-common.sh.
source "${script_dir}/lib/check-common.sh"
# The GitHub coordinates, the registry coordinate, the shared paths and the
# patterns derived from them are declared once — see scripts/lib/repo-context.sh
# and INVARIANTS.md § Encapsulation.
source "${script_dir}/lib/repo-context.sh"
# The credential shapes this repo refuses to publish, and the scan itself, are
# shared with scripts/check-secret-leak.sh — see scripts/lib/secret-patterns.sh.
source "${script_dir}/lib/secret-patterns.sh"

readonly HELPER="${script_dir}/lib/manifest_data.py"

# The gates this driver depends on, named once. The same list is guarded for
# existence before anything runs and re-run against the tree afterwards; two
# hand-kept copies of it could disagree about which gates a release is verified
# by.
readonly GATES=(
  check-version-drift
  check-release-notes-drift
  check-deploy-contract
  check-secret-leak
)

# POSIX ERE only — no \d, \s or \b (INVARIANTS.md § Tool invocation correctness).
# Anchored at line start, which is the entire reason the indented `Manifests:`
# entries in the inspect output can never be read as the index digest.
readonly TOP_LEVEL_DIGEST_ERE="^Digest:[[:space:]]+${DIGEST_ERE}[[:space:]]*$"

# The verified finding this script refuses markdown on. Stated once, quoted by
# each of the three refusals.
readonly MARKDOWN_RATIONALE="Umbrel's Markdown component short-circuits for community app stores: on a /community-app-store page it renders the raw string in a plain whitespace-pre-line div and bypasses react-markdown entirely, so '**' renders as literal asterisks, a [text](url) link as literal brackets and parens, and a leading '#' as literal hashes. The updates dialog renders the SAME string through the same component but keys on the CURRENT route, so opened from outside /community-app-store it DOES render markdown. Two surfaces, two results — plain prose is the only spelling correct on both (DECISIONS.md entry 11). Edit the Release body upstream, then re-run."

# --- guards: CLI, then work tree, then files ---------------------------------

for tool in docker gh git python3; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "${tool} not found on PATH; the release driver needs it (the push-time gates do not — see DECISIONS.md entry 13)"
done

git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "${repo_root} is not a git work tree; the release driver commits and pushes a release branch"

manifest="${repo_root}/${MANIFEST_REL_PATH}"
compose="${repo_root}/${COMPOSE_REL_PATH}"
[[ -f "$HELPER" ]] || fail "shared manifest parser not found at ${HELPER}"
[[ -f "$manifest" ]] || fail "app manifest not found at ${manifest}"
[[ -f "$compose" ]] || fail "compose file not found at ${compose}"
for gate in "${GATES[@]}"; do
  [[ -f "${script_dir}/${gate}.sh" ]] || fail "gate script not found at ${script_dir}/${gate}.sh"
done

# --- the argument is a version, and only ever a version ----------------------

(( $# == 1 )) || fail "usage: scripts/release.sh X.Y.Z — one argument, the semver to pin"
version="$1"
if [[ "$version" == *"@"* || "$version" == *"sha256:"* ]]; then
  fail "'${version}' carries an image digest. This script never accepts a digest as an argument and never reads one from a file the upstream repo produced — it resolves the multi-arch index digest from the registry itself (DECISIONS.md entry 4). Pass the semver alone, for example: scripts/release.sh 0.3.0"
fi
[[ "$version" =~ ^${SEMVER_ERE}$ ]] || fail "'${version}' is not a semver of the form X.Y.Z"

# --- staging ------------------------------------------------------------------
#
# Everything fetched lands here first. The tree is written only after the
# credential refusal and the contract assertion have both passed, which is what
# makes "a refusal leaves the tree untouched" literally true rather than merely
# intended.
#
# ONE cleanup handler for this scope (codespace docs/coding-standards.md § 9.3 —
# a second `trap ... EXIT` here would silently replace it). INT and TERM exit so
# the single EXIT handler stays the only thing that removes the staging dir.
staging=""
cleanup() {
  if [[ -n "$staging" && -d "$staging" ]]; then
    rm -rf "$staging"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

staging="$(mktemp -d)"
staged_notes="${staging}/${VENDOR_NOTES_NAME}"
staged_contract="${staging}/${VENDOR_CONTRACT_NAME}"

# --- 1. resolve the index digest from the registry ---------------------------

printf 'release: resolving the index digest for %s:%s\n' "$UPSTREAM_IMAGE" "$version"
if ! docker buildx imagetools inspect "${UPSTREAM_IMAGE}:${version}" \
     > "${staging}/inspect.out" 2> "${staging}/inspect.err"; then
  fail "docker buildx imagetools inspect ${UPSTREAM_IMAGE}:${version} failed: $(cat "${staging}/inspect.err")"
fi

digest_matches="$(grep -cE "$TOP_LEVEL_DIGEST_ERE" "${staging}/inspect.out" || true)"
if (( digest_matches != 1 )); then
  fail "expected exactly one top-level 'Digest:' line in the inspect output for ${UPSTREAM_IMAGE}:${version}, found ${digest_matches}. The index digest is the ONLY value this script pins; the indented entries under 'Manifests:' are per-platform manifests and are never used (DECISIONS.md entry 4)."
fi
digest="$(grep -E "$TOP_LEVEL_DIGEST_ERE" "${staging}/inspect.out" \
  | sed -E 's/^Digest:[[:space:]]+//; s/[[:space:]]*$//')"
printf 'release: index digest %s\n' "$digest"

# --- 2. fetch the upstream Release body --------------------------------------

printf 'release: fetching the %s Release body for v%s\n' "$UPSTREAM_REPO_SLUG" "$version"
if ! gh release view "v${version}" --repo "$UPSTREAM_REPO_SLUG" --json body -q .body \
     > "$staged_notes" 2> "${staging}/release.err"; then
  fail "gh release view v${version} --repo ${UPSTREAM_REPO_SLUG} failed: $(cat "${staging}/release.err"). A missing Release is a hard failure: the listing's releaseNotes is a copy of the Release and is never authored here (DECISIONS.md entry 10). Publish the Release upstream, then re-run."
fi
if [[ ! -s "$staged_notes" ]]; then
  fail "the ${UPSTREAM_REPO_SLUG} Release v${version} has an empty body. There is no fall-through to hand-written text (DECISIONS.md entry 10) — write the Release body upstream, then re-run."
fi

# --- 3. refuse markdown -------------------------------------------------------

if grep -qF '**' "$staged_notes"; then
  fail "the v${version} Release body contains '**' (bold markdown). ${MARKDOWN_RATIONALE}"
fi
if grep -qE '\[[^]]+\]\([^)]+\)' "$staged_notes"; then
  fail "the v${version} Release body contains a [text](url) markdown link. ${MARKDOWN_RATIONALE}"
fi
if grep -qE '^#' "$staged_notes"; then
  fail "the v${version} Release body contains a line beginning with '#' (a markdown heading). ${MARKDOWN_RATIONALE}"
fi

# The body must also be something the folded-scalar emitter can represent. This
# runs against the staged copy, so a body carrying a tab, a CRLF ending or
# trailing whitespace fails before the tree is touched rather than after.
emitter_check="$(python3 "$HELPER" round-trip "$staged_notes" "$NOTES_BLOCK_INDENT" 2>&1 >/dev/null)" \
  || fail "the v${version} Release body cannot be written as a YAML folded scalar: ${emitter_check}"

# --- 4. fetch the deployment contract AT THE PINNED TAG ----------------------

printf 'release: fetching %s at tag v%s\n' "$UPSTREAM_CONTRACT_PATH" "$version"
if ! gh api -H "Accept: application/vnd.github.raw" \
     "repos/${UPSTREAM_REPO_SLUG}/contents/${UPSTREAM_CONTRACT_PATH}?ref=v${version}" \
     > "$staged_contract" 2> "${staging}/contract.err"; then
  fail "could not fetch ${UPSTREAM_CONTRACT_PATH} from ${UPSTREAM_REPO_SLUG} at tag v${version}: $(cat "${staging}/contract.err"). The contract is read at the PINNED TAG, never at main and never at an unpinned ref — a tag whose tree carries no contract cannot be pinned by this store."
fi
if [[ ! -s "$staged_contract" ]]; then
  fail "${UPSTREAM_CONTRACT_PATH} at ${UPSTREAM_REPO_SLUG} tag v${version} is empty"
fi

# --- 5. refuse a credential in either staged artefact ------------------------
#
# BOTH artefacts, not just the Release body. The contract is JSON generated
# upstream, but its `documentation.*` fields are free prose a human writes, and
# until this check existed it was copied into the tree verbatim with no content
# check of any kind.
#
# WHY THIS CHECK ALSO EXISTS AS A PUSH-TIME GATE. This one runs where the text
# ENTERS the tree; `scripts/check-secret-leak.sh` runs where the tree becomes
# PUBLIC. A control at only one of those leaves the other open: a hand edit made
# by DEPLOY.md § 3.1's recovery path never reaches this script at all, and it
# satisfies `check-release-notes-drift.sh` as long as it changes the manifest and
# the vendored copy together. Both places, one definition of the shapes
# (scripts/lib/secret-patterns.sh). See that gate's header and DECISIONS.md
# entry 15 for the full reasoning.
#
# It runs HERE, on the staged copies, rather than only in the post-write
# verification below, so a refusal leaves the working tree exactly as it was —
# the same ordering rule the contract assertion follows. A credential written
# into the tree and only then refused would already be sitting in the checkout.

staged_category=""
if ! secret_scan_file staged_category "$staged_notes"; then
  fail "the v${version} Release body contains ${staged_category}. ${SECRET_LEAK_RATIONALE} Nothing has been written — the working tree is exactly as it was. Edit the Release body upstream, then re-run."
fi
if ! secret_scan_file staged_category "$staged_contract"; then
  fail "${UPSTREAM_CONTRACT_PATH} at ${UPSTREAM_REPO_SLUG} tag v${version} contains ${staged_category}. ${SECRET_LEAK_RATIONALE} Nothing has been written — the working tree is exactly as it was. Correct the contract upstream, re-tag, then re-run."
fi

# --- 6. assert the contract BEFORE any file is written -----------------------

printf 'release: asserting the v%s deployment contract against the current compose\n' "$version"
if ! bash "${script_dir}/check-deploy-contract.sh" --contract "$staged_contract" --compose "$compose"; then
  fail "the v${version} deployment contract is not satisfied by the current ${COMPOSE_REL_PATH}. NOTHING has been written — the working tree is exactly as it was. Reconcile the compose with the contract (this repo asserts against the contract and never generates from it, DECISIONS.md entry 12), then re-run."
fi

# --- 7. the release branch ----------------------------------------------------

branch="release-${version}"
current_branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" != "$branch" ]]; then
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/${branch}"; then
    git -C "$repo_root" checkout "$branch"
  else
    git -C "$repo_root" checkout -b "$branch"
  fi
fi

# --- 8. write the tree --------------------------------------------------------

vendor_root="${repo_root}/${VENDOR_REL_DIR}"
mkdir -p "$vendor_root"
# Every previous vendored version directory goes, so exactly one survives and
# the gates' staleness guard has one answer to read.
shopt -s nullglob
for previous in "${vendor_root}"/*/; do
  rm -rf "$previous"
done
shopt -u nullglob

vendor_dir="${vendor_root}/v${version}"
mkdir -p "$vendor_dir"
cp "$staged_notes" "${vendor_dir}/${VENDOR_NOTES_NAME}"
cp "$staged_contract" "${vendor_dir}/${VENDOR_CONTRACT_NAME}"
chmod 644 "${vendor_dir}/${VENDOR_NOTES_NAME}" "${vendor_dir}/${VENDOR_CONTRACT_NAME}"

set_scalar_out="$(python3 "$HELPER" set-scalar "$manifest" version "$version" 2>&1)" \
  || fail "$set_scalar_out"
set_block_out="$(python3 "$HELPER" set-block "$manifest" releaseNotes "${vendor_dir}/${VENDOR_NOTES_NAME}" "$NOTES_BLOCK_INDENT" 2>&1)" \
  || fail "$set_block_out"

# The image reference carries the tag AND the digest, and both halves move
# together (DECISIONS.md entry 3). COMPOSE_IMAGE_ERE is the whole-line pattern
# for that reference, declared in scripts/lib/repo-context.sh and shared with
# check-version-drift — the gate that reads the tag back out matches on exactly
# the pattern this rewrite emits.
image_matches="$(grep -cE "$COMPOSE_IMAGE_ERE" "$compose" || true)"
if (( image_matches != 1 )); then
  fail "expected exactly one pinned '${UPSTREAM_IMAGE}' image line in ${COMPOSE_REL_PATH}, found ${image_matches}; cannot determine which to rewrite"
fi
# A temp file plus a copy back, rather than `sed -i`, which is a GNU extension.
# \1 is the line through to the image name and \3 is whatever trailed the
# digest, so a comment beside the pin survives the rewrite untouched.
sed -E "s|${COMPOSE_IMAGE_ERE}|\\1:${version}@${digest}\\3|" "$compose" > "${staging}/compose.out"
cat "${staging}/compose.out" > "$compose"

printf 'release: wrote version %s, image tag %s and digest %s\n' "$version" "$version" "$digest"

# --- 9. verify the written tree ----------------------------------------------

printf 'release: re-running the gates against the written tree\n'
for gate in "${GATES[@]}"; do
  bash "${script_dir}/${gate}.sh" \
    || fail "post-write verification failed: ${gate}.sh does not pass against the tree this run just wrote. The tree is on branch ${branch} and nothing has been committed."
done

# --- 10. commit, push, and open the PR exactly once --------------------------

git -C "$repo_root" add --all -- \
  "$VENDOR_REL_DIR" "$MANIFEST_REL_PATH" "$COMPOSE_REL_PATH"

if git -C "$repo_root" diff --cached --quiet; then
  printf 'release: the tree already matches %s; no new commit needed\n' "$version"
else
  git -C "$repo_root" commit -m "chore(release): pin miner-fleet ${version}"
fi

remote="${RELEASE_REMOTE:-}"
if [[ -z "$remote" ]]; then
  remote="$(git -C "$repo_root" remote | head -n 1)"
fi
[[ -n "$remote" ]] || fail "no git remote is configured, so the release branch cannot be pushed; set RELEASE_REMOTE or add a remote"

git -C "$repo_root" push --set-upstream "$remote" "$branch"

existing_pr="$(gh pr list --repo "$STORE_REPO_SLUG" --head "$branch" --state open --json number -q '.[0].number' 2>&1)" \
  || fail "gh pr list --repo ${STORE_REPO_SLUG} --head ${branch} failed: ${existing_pr}"

if [[ -n "$existing_pr" ]]; then
  printf 'release: PR #%s is already open for %s — branch updated in place, no duplicate opened\n' \
    "$existing_pr" "$branch"
else
  gh pr create --repo "$STORE_REPO_SLUG" --head "$branch" \
    --title "chore(release): pin miner-fleet ${version}" \
    --body "Pins ${UPSTREAM_IMAGE}:${version}@${digest}.

The digest is the multi-arch INDEX digest read from the registry's top-level \`Digest:\` line, never a per-platform manifest digest (DECISIONS.md entry 4).

\`releaseNotes\` is the ${UPSTREAM_REPO_SLUG} Release body for v${version}, fetched and vendored at \`${VENDOR_REL_DIR}/v${version}/${VENDOR_NOTES_NAME}\` — it is never authored here (DECISIONS.md entry 10).

The deployment contract at tag v${version} was asserted against \`${COMPOSE_REL_PATH}\` before any file was written, and is vendored at \`${VENDOR_REL_DIR}/v${version}/${VENDOR_CONTRACT_NAME}\`.

Verified after the write by \`check-version-drift.sh\`, \`check-release-notes-drift.sh\` and \`check-deploy-contract.sh\`."
fi

printf 'release: done — %s pinned on branch %s\n' "$version" "$branch"

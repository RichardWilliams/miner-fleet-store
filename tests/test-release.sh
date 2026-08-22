#!/usr/bin/env bash
#
# Tests for scripts/release.sh.
#
# Every case builds its own miniature store repo under the harness scratch dir —
# the driver, the three gates it runs, the libraries they source, an app
# manifest and compose file pinned at a previous version, and a git work tree
# with a bare local remote to push to (codespace docs/testing-standards.md
# § 4.1, hermetic fixtures).
#
# `docker` and `gh` are STUBBED through a FAKE_BIN directory prepended to PATH,
# and both stubs FAIL CLOSED (exit 64) on any invocation they were not built to
# answer — including a wrong `--repo` slug, a wrong tag, or a wrong API path
# (§ 3.1 fail-closed stubs). No case can silently reach a real registry, a real
# GitHub API, or the network. The `git` calls are real, against a bare repo
# created beside the fixture, so the branch-and-push path is exercised without
# leaving the machine.
#
# The stubs read their canned answers from files under the fixture's own
# `.stub/` directory, located relative to the stub's own path, so no case has to
# plumb environment variables through a bash function (codespace
# docs/coding-standards.md § 9.1).

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"
readonly SCRIPT_UNDER_TEST="${repo_root}/scripts/release.sh"
readonly COMMON_LIB="${repo_root}/scripts/lib/check-common.sh"
readonly CONTEXT_LIB="${repo_root}/scripts/lib/repo-context.sh"
readonly PARSER_LIB="${repo_root}/scripts/lib/manifest_data.py"
readonly PATTERNS_LIB="${repo_root}/scripts/lib/secret-patterns.sh"

# The app id, the registry coordinate and both GitHub slugs come from the one
# place that declares them, so no coordinate is written a second time here.
[[ -f "$CONTEXT_LIB" ]] || {
  printf 'FATAL: repo context library not found at %s\n' "$CONTEXT_LIB" >&2
  exit 1
}
source "$CONTEXT_LIB"

readonly PREVIOUS_VERSION="0.2.0"
readonly TARGET_VERSION="0.3.0"
readonly PREVIOUS_DIGEST="sha256:83de64211b8e6b0293df25fa718d387f5a07e8c841da80b5792213461f3d50ab"
readonly INDEX_DIGEST="sha256:27c16fba762479efa4773aa477ede79e96f67bb633c554baa1d820f0429419f8"
# The per-platform digest that sits in the indented `Manifests:` list. Reading
# it instead of the index digest is the mistake DECISIONS.md entry 4 names, and
# it is what the fixture inspect output is built to tempt.
readonly PLATFORM_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"

readonly GATES=(
  check-version-drift
  check-release-notes-drift
  check-deploy-contract
  check-secret-leak
)

for required in "$SCRIPT_UNDER_TEST" "$COMMON_LIB" "$CONTEXT_LIB" "$PARSER_LIB" \
  "$PATTERNS_LIB"; do
  [[ -f "$required" ]] || {
    printf 'FATAL: file under test not found at %s\n' "$required" >&2
    exit 1
  }
done
for gate in "${GATES[@]}"; do
  [[ -f "${repo_root}/scripts/${gate}.sh" ]] || {
    printf 'FATAL: gate not found at %s\n' "${repo_root}/scripts/${gate}.sh" >&2
    exit 1
  }
done

harness="${script_dir}/lib/bash-test-harness.sh"
[[ -f "$harness" ]] || {
  printf 'FATAL: shared test harness not found at %s\n' "$harness" >&2
  exit 1
}
source "$harness"

# ---------------------------------------------------------------------------
# Canned upstream answers.
# ---------------------------------------------------------------------------

INSPECT_OUTPUT="$(cat <<INSPECT
Name:      ${UPSTREAM_IMAGE}:${TARGET_VERSION}
MediaType: application/vnd.oci.image.index.v1+json
Digest:    ${INDEX_DIGEST}

Manifests:
  Name:      ${UPSTREAM_IMAGE}:${TARGET_VERSION}@${PLATFORM_DIGEST}
  Digest:    ${PLATFORM_DIGEST}
  MediaType: application/vnd.oci.image.manifest.v1+json
  Platform:  linux/amd64
INSPECT
)"

RELEASE_BODY="$(cat <<'BODY'
Miner Fleet 0.3.0

Firmware versions are now visible across the fleet. Each board shows the
firmware it is running alongside the latest release published for its model.

Two fixes to how the app watches your fleet:

  - Warnings now fire for boards found by network discovery.
  - The app now runs a single polling loop.
BODY
)"

PREVIOUS_BODY="$(cat <<'BODY'
Miner Fleet 0.2.0

The fleet is live.
BODY
)"

CONTRACT_JSON="$(cat <<'CONTRACT'
{
  "documentation": {
    "purpose": "Prose the gate ignores by design.",
    "requiredEnvKeysMeaning": "The keys without which the container fails to start.",
    "packagingAffecting": "The facts the packaging depends on.",
    "nonPackagingAffecting": "Tunables that never need a coordinated release."
  },
  "packagingAffecting": {
    "containerPort": 3000,
    "healthPath": "/api/health",
    "dataDirectory": {
      "envKey": "MINER_FLEET_DATA_DIR",
      "default": "/data"
    },
    "requiredEnvKeys": []
  },
  "nonPackagingAffecting": {
    "optionalEnvKeys": [
      { "key": "MINER_FLEET_SUBNETS" }
    ]
  }
}
CONTRACT
)"

COMPOSE_BODY="$(cat <<COMPOSE
services:
  app_proxy:
    environment:
      APP_HOST: ${APP_ID}_server_1
      APP_PORT: 3000

  server:
    image: ${UPSTREAM_IMAGE}:${PREVIOUS_VERSION}@${PREVIOUS_DIGEST}  # index digest, not per-platform
    restart: on-failure
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 30s
    volumes:
      - \${APP_DATA_DIR}/data:/data
    env_file:
      - path: \${APP_DATA_DIR}/data/config.env
        required: false
COMPOSE
)"

# ---------------------------------------------------------------------------
# Fixture construction.
# ---------------------------------------------------------------------------

write_docker_stub() {
  cat > "${1}/fake-bin/docker" <<'STUB'
#!/usr/bin/env bash
# Fail-closed docker stub. Answers exactly one invocation shape and refuses
# every other, so no case can reach a real registry by accident.
set -euo pipefail
stub_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stub="$(cd -P "${stub_dir}/.." && pwd)/.stub"

if [[ "${1:-}" == "buildx" && "${2:-}" == "imagetools" && "${3:-}" == "inspect" && $# -eq 4 ]]; then
  expected="$(cat "${stub}/expected-image-ref")"
  if [[ "$4" != "$expected" ]]; then
    printf 'docker stub: unexpected image reference %s (expected %s)\n' "$4" "$expected" >&2
    exit 64
  fi
  if [[ -f "${stub}/inspect.fail" ]]; then
    printf 'ERROR: %s: not found\n' "$4" >&2
    exit 1
  fi
  cat "${stub}/inspect.out"
  exit 0
fi

printf 'docker stub: refusing unexpected invocation: %s\n' "$*" >&2
exit 64
STUB
  chmod +x "${1}/fake-bin/docker"
}

write_gh_stub() {
  cat > "${1}/fake-bin/gh" <<'STUB'
#!/usr/bin/env bash
# Fail-closed gh stub. Every answer is canned from the fixture's .stub
# directory, and every invocation shape not enumerated here exits 64 — including
# a wrong --repo slug, a wrong tag, or an unpinned contract path.
set -euo pipefail
stub_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stub="$(cd -P "${stub_dir}/.." && pwd)/.stub"

refuse() {
  printf 'gh stub: %s\n' "$1" >&2
  exit 64
}

flag_value() {
  local wanted="$1"
  shift
  while (( $# > 0 )); do
    if [[ "$1" == "$wanted" ]]; then
      printf '%s' "${2:-}"
      return 0
    fi
    shift
  done
  return 1
}

upstream_slug="$(cat "${stub}/upstream-slug")"
store_slug="$(cat "${stub}/store-slug")"
version="$(cat "${stub}/version")"

command="${1:-}"
sub="${2:-}"

if [[ "$command" == "release" && "$sub" == "view" ]]; then
  repo="$(flag_value --repo "$@")" || refuse "release view carried no --repo"
  [[ "$repo" == "$upstream_slug" ]] || refuse "release view named ${repo}, not ${upstream_slug}"
  [[ "${3:-}" == "v${version}" ]] || refuse "release view named tag ${3:-}, not v${version}"
  if [[ -f "${stub}/release.fail" ]]; then
    printf 'release not found\n' >&2
    exit 1
  fi
  cat "${stub}/release-body.txt"
  exit 0
fi

if [[ "$command" == "api" ]]; then
  api_path=""
  for argument in "$@"; do
    case "$argument" in
      repos/*) api_path="$argument" ;;
    esac
  done
  [[ -n "$api_path" ]] || refuse "api carried no repos/ path"
  expected="repos/${upstream_slug}/contents/deploy/contract.json?ref=v${version}"
  [[ "$api_path" == "$expected" ]] || refuse "api asked for ${api_path}, not ${expected}"
  if [[ -f "${stub}/contract.fail" ]]; then
    printf 'Not Found\n' >&2
    exit 1
  fi
  cat "${stub}/contract.json"
  exit 0
fi

if [[ "$command" == "pr" && "$sub" == "list" ]]; then
  repo="$(flag_value --repo "$@")" || refuse "pr list carried no --repo"
  [[ "$repo" == "$store_slug" ]] || refuse "pr list named ${repo}, not ${store_slug}"
  if [[ -f "${stub}/pr-number" ]]; then
    cat "${stub}/pr-number"
  fi
  exit 0
fi

if [[ "$command" == "pr" && "$sub" == "create" ]]; then
  repo="$(flag_value --repo "$@")" || refuse "pr create carried no --repo"
  [[ "$repo" == "$store_slug" ]] || refuse "pr create named ${repo}, not ${store_slug}"
  head="$(flag_value --head "$@")" || refuse "pr create carried no --head"
  printf '%s\n' "$head" >> "${stub}/pr-created.log"
  printf '77\n' > "${stub}/pr-number"
  printf 'https://github.com/%s/pull/77\n' "$repo"
  exit 0
fi

refuse "refusing unexpected invocation: $*"
STUB
  chmod +x "${1}/fake-bin/gh"
}

# $1 = fixture name. Returns the fixture root on stdout.
make_fixture() {
  local name="$1"
  local root="${scratch}/${name}"
  mkdir -p "${root}/scripts/lib" "${root}/${APP_ID}" \
    "${root}/${VENDOR_REL_DIR}/v${PREVIOUS_VERSION}" "${root}/fake-bin" "${root}/.stub"

  cp "$SCRIPT_UNDER_TEST" "${root}/scripts/release.sh"
  chmod +x "${root}/scripts/release.sh"
  local gate=""
  for gate in "${GATES[@]}"; do
    cp "${repo_root}/scripts/${gate}.sh" "${root}/scripts/${gate}.sh"
    chmod +x "${root}/scripts/${gate}.sh"
  done
  cp "$COMMON_LIB" "${root}/scripts/lib/check-common.sh"
  cp "$CONTEXT_LIB" "${root}/scripts/lib/repo-context.sh"
  cp "$PARSER_LIB" "${root}/scripts/lib/manifest_data.py"
  cp "$PATTERNS_LIB" "${root}/scripts/lib/secret-patterns.sh"

  cat > "${root}/${APP_ID}/umbrel-app.yml" <<EOF
manifestVersion: 1
id: ${APP_ID}
name: Miner Fleet
version: "${PREVIOUS_VERSION}"
port: 3007
releaseNotes: >-
  replaced below by the real emitter
# A load-bearing comment the surgery must not delete.
developer: Pipfox
EOF
  printf '%s\n' "$PREVIOUS_BODY" > "${root}/${VENDOR_REL_DIR}/v${PREVIOUS_VERSION}/release-notes.txt"
  printf '%s\n' "$CONTRACT_JSON" > "${root}/${VENDOR_REL_DIR}/v${PREVIOUS_VERSION}/contract.json"
  python3 "${root}/scripts/lib/manifest_data.py" set-block \
    "${root}/${APP_ID}/umbrel-app.yml" releaseNotes \
    "${root}/${VENDOR_REL_DIR}/v${PREVIOUS_VERSION}/release-notes.txt" \
    "$NOTES_BLOCK_INDENT"

  printf '%s\n' "$COMPOSE_BODY" > "${root}/${APP_ID}/docker-compose.yml"

  printf '%s\n' "$INSPECT_OUTPUT" > "${root}/.stub/inspect.out"
  printf '%s\n' "$RELEASE_BODY" > "${root}/.stub/release-body.txt"
  printf '%s\n' "$CONTRACT_JSON" > "${root}/.stub/contract.json"
  printf '%s' "${UPSTREAM_IMAGE}:${TARGET_VERSION}" > "${root}/.stub/expected-image-ref"
  printf '%s' "$UPSTREAM_REPO_SLUG" > "${root}/.stub/upstream-slug"
  printf '%s' "$STORE_REPO_SLUG" > "${root}/.stub/store-slug"
  printf '%s' "$TARGET_VERSION" > "${root}/.stub/version"

  write_docker_stub "$root"
  write_gh_stub "$root"

  git init --quiet "$root"
  git -C "$root" symbolic-ref HEAD refs/heads/main
  git -C "$root" config user.email "release-driver-tests@example.invalid"
  git -C "$root" config user.name "Release Driver Tests"
  git -C "$root" add --all
  git -C "$root" commit --quiet -m "fixture: the store at ${PREVIOUS_VERSION}"
  git init --quiet --bare "${root}.git"
  git -C "$root" remote add origin "${root}.git"

  printf '%s' "$root"
}

# $1 = description, $2 = expected exit, $3 = substring, $4 = fixture root,
# $5... = the driver's own arguments.
run_release() {
  local desc="$1" expected="$2" substring="$3" root="$4"
  shift 4
  local saved_path="$PATH"
  export PATH="${root}/fake-bin:${saved_path}"
  assert_case "$desc" "$expected" "$substring" bash "${root}/scripts/release.sh" "$@"
  export PATH="$saved_path"
}

# A snapshot-run-compare helper, so "the tree is untouched" is asserted against
# the actual bytes rather than against the driver's own claim.
readonly UNTOUCHED_CHECK="${scratch}/assert-tree-untouched.sh"
cat > "$UNTOUCHED_CHECK" <<'UNTOUCHED'
#!/usr/bin/env bash
# $1 = fixture root, $2 = version argument.
set -euo pipefail
root="$1"
version="$2"

# The fixture's own copy of the context library names the two directories a
# release bump may write to, so this helper reads them from the same
# declaration the driver does.
source "${root}/scripts/lib/repo-context.sh"

snapshot() {
  cd "$root"
  find "${APP_ID}" "${VENDOR_REL_DIR}" -type f | sort | while read -r entry; do
    printf '=== %s\n' "$entry"
    cat "$entry"
  done
}

before="$(snapshot)"
driver_exit=0
PATH="${root}/fake-bin:${PATH}" bash "${root}/scripts/release.sh" "$version" \
  > "${root}/.stub/driver.out" 2>&1 || driver_exit=$?
after="$(snapshot)"

if [[ "$before" != "$after" ]]; then
  printf 'the driver modified the tree; it should not have\n' >&2
  exit 1
fi
printf 'tree untouched, driver exited %d\n' "$driver_exit"
UNTOUCHED

# The driver's own run-and-check-absence helper. assert_case can require a
# substring to be PRESENT; the property here is that one is ABSENT, because a
# refusal that quoted the credential would disclose it into the terminal and the
# CI log of every run that reproduced it.
readonly NO_ECHO_CHECK="${scratch}/assert-driver-secret-not-echoed.sh"
cat > "$NO_ECHO_CHECK" <<'NOECHO'
#!/usr/bin/env bash
# $1 = fixture root, $2 = version argument, $3 = the literal that must not
# appear anywhere in the driver's output.
set -euo pipefail
seen=""
seen="$(PATH="${1}/fake-bin:${PATH}" bash "${1}/scripts/release.sh" "$2" 2>&1)" || true

if [[ "$seen" == *"$3"* ]]; then
  printf 'the driver echoed the matched credential back into its own output\n' >&2
  exit 1
fi
printf 'driver named the category and not the credential\n'
NOECHO

readonly PR_COUNT_CHECK="${scratch}/count-created-prs.sh"
cat > "$PR_COUNT_CHECK" <<'COUNT'
#!/usr/bin/env bash
# $1 = the stub's pr-created log.
set -euo pipefail
if [[ -f "$1" ]]; then
  printf 'pr create invocations: %s\n' "$(grep -c '' "$1")"
else
  printf 'pr create invocations: 0\n'
fi
COUNT

# ---------------------------------------------------------------------------
# THE ARGUMENT IS A VERSION, NEVER A DIGEST. The driver resolves the digest from
# the registry itself, so there is no argument, and no file produced upstream,
# that could carry one in.
# ---------------------------------------------------------------------------
root="$(make_fixture rejects_digest_argument)"
run_release 'argument: a tag@digest argument is rejected' 1 'never accepts a digest' \
  "$root" "${TARGET_VERSION}@${INDEX_DIGEST}"
run_release 'argument: a bare digest argument is rejected' 1 'never accepts a digest' \
  "$root" "$INDEX_DIGEST"
run_release 'argument: a non-semver argument is rejected' 1 'is not a semver' "$root" 'latest'
run_release 'argument: no argument at all is rejected' 1 'usage' "$root"

# ---------------------------------------------------------------------------
# THE HAPPY PATH. One run rewrites the version, the image tag and the digest
# together, vendors both upstream artefacts, and opens exactly one PR.
# ---------------------------------------------------------------------------
root="$(make_fixture happy_path)"
run_release 'release: a clean run succeeds' 0 'done' "$root" "$TARGET_VERSION"

assert_case 'digest: the pinned digest is the TOP-LEVEL Digest, not the indented per-platform one' \
  0 "${TARGET_VERSION}@${INDEX_DIGEST}" \
  grep -F 'image:' "${root}/${APP_ID}/docker-compose.yml"

assert_case 'digest: the per-platform digest from the Manifests list is never pinned' \
  1 '' grep -F "$PLATFORM_DIGEST" "${root}/${APP_ID}/docker-compose.yml"

assert_case 'bump: the manifest version is rewritten' 0 "$TARGET_VERSION" \
  python3 "$PARSER_LIB" get "${root}/${APP_ID}/umbrel-app.yml" version

assert_case 'bump: the listing carries the upstream Release body' 0 'Firmware versions are now visible' \
  python3 "$PARSER_LIB" get "${root}/${APP_ID}/umbrel-app.yml" releaseNotes

assert_case 'bump: the manifest surgery preserved the surrounding comment' 0 'load-bearing comment' \
  grep -F '# A load-bearing comment' "${root}/${APP_ID}/umbrel-app.yml"

assert_case 'bump: version drift passes against the written tree' 0 'OK' \
  bash "${root}/scripts/check-version-drift.sh"

assert_case 'bump: release-notes drift passes against the written tree' 0 'OK' \
  bash "${root}/scripts/check-release-notes-drift.sh"

assert_case 'bump: the deployment contract passes against the written tree' 0 'OK' \
  bash "${root}/scripts/check-deploy-contract.sh"

assert_case 'bump: the credential gate passes against the written tree' 0 'OK' \
  bash "${root}/scripts/check-secret-leak.sh"

assert_case 'vendor: the new version directory is written' 0 '' \
  test -f "${root}/${VENDOR_REL_DIR}/v${TARGET_VERSION}/contract.json"

assert_case 'vendor: the previous version directory is removed' 1 '' \
  test -d "${root}/${VENDOR_REL_DIR}/v${PREVIOUS_VERSION}"

assert_case 'pr: exactly one PR was opened' 0 'pr create invocations: 1' \
  bash "$PR_COUNT_CHECK" "${root}/.stub/pr-created.log"

# ---------------------------------------------------------------------------
# RESUMABLE. A second run for the same version rewrites the same content and
# finds the open PR rather than opening a second one.
# ---------------------------------------------------------------------------
run_release 'resume: a re-run for the same version succeeds' 0 'already open' \
  "$root" "$TARGET_VERSION"

assert_case 'resume: still exactly one PR' 0 'pr create invocations: 1' \
  bash "$PR_COUNT_CHECK" "${root}/.stub/pr-created.log"

# ---------------------------------------------------------------------------
# A MISSING OR EMPTY RELEASE IS A HARD FAILURE, and it leaves the tree alone.
# There is no fall-through to hand-written notes.
# ---------------------------------------------------------------------------
root="$(make_fixture missing_release)"
touch "${root}/.stub/release.fail"
run_release 'release notes: a missing upstream Release is a hard failure' 1 'A missing Release is a hard failure' \
  "$root" "$TARGET_VERSION"
assert_case 'release notes: a missing Release leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"

root="$(make_fixture empty_release)"
: > "${root}/.stub/release-body.txt"
run_release 'release notes: an empty upstream Release body is a hard failure' 1 'empty body' \
  "$root" "$TARGET_VERSION"
assert_case 'release notes: an empty Release body leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"

# ---------------------------------------------------------------------------
# MARKDOWN IS REFUSED, with the verified community-store rationale. All three
# shapes the acceptance criteria name.
# ---------------------------------------------------------------------------
root="$(make_fixture markdown_bold)"
printf 'Discovery is **live** now.\n' > "${root}/.stub/release-body.txt"
run_release 'markdown: a bold body is refused' 1 "contains '**'" "$root" "$TARGET_VERSION"
run_release 'markdown: the refusal cites the community-store bypass' 1 'bypasses react-markdown' \
  "$root" "$TARGET_VERSION"

root="$(make_fixture markdown_link)"
printf 'See [the docs](https://example.invalid/docs).\n' > "${root}/.stub/release-body.txt"
run_release 'markdown: a link body is refused' 1 'markdown link' "$root" "$TARGET_VERSION"
run_release 'markdown: the link refusal cites the community-store bypass' 1 'whitespace-pre-line' \
  "$root" "$TARGET_VERSION"

root="$(make_fixture markdown_heading)"
printf '# Heading\n\nBody text.\n' > "${root}/.stub/release-body.txt"
run_release 'markdown: a heading body is refused' 1 'markdown heading' "$root" "$TARGET_VERSION"
assert_case 'markdown: a refused body leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"

# ---------------------------------------------------------------------------
# THE CONTRACT ASSERTION RUNS BEFORE ANY FILE IS WRITTEN. A mismatch leaves the
# tree completely untouched — including the vendored artefacts themselves, which
# is what the temp-staging design buys.
# ---------------------------------------------------------------------------
root="$(make_fixture contract_mismatch)"
printf '%s\n' "$CONTRACT_JSON" \
  | sed -E 's/"containerPort": 3000/"containerPort": 4000/' \
  > "${root}/.stub/contract.json"
run_release 'contract: a mismatch fails the release' 1 'is not satisfied by the current' \
  "$root" "$TARGET_VERSION"
run_release 'contract: the failure names the container-port mismatch' 1 'container-port mismatch' \
  "$root" "$TARGET_VERSION"
assert_case 'contract: a mismatch leaves the tree completely untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"

root="$(make_fixture contract_missing_at_tag)"
touch "${root}/.stub/contract.fail"
run_release 'contract: a tag whose tree carries no contract is a hard failure' 1 'at tag v' \
  "$root" "$TARGET_VERSION"
assert_case 'contract: an absent contract leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"

# ---------------------------------------------------------------------------
# A CREDENTIAL IN EITHER FETCHED ARTEFACT IS REFUSED BEFORE ANYTHING IS WRITTEN.
# This repo is public and its history is permanent; the repo these two artefacts
# are copied FROM is private. The refusal names the CATEGORY and never the
# matched text, and it leaves the tree untouched, exactly as the markdown and
# contract refusals do (DECISIONS.md entry 15).
#
# The fixture values are not credentials: the AWS row is the key id AWS
# publishes in its own documentation as the example value, and the GitHub row is
# EXAMPLE filler at the length the shape requires.
# ---------------------------------------------------------------------------
readonly EXAMPLE_AWS_KEY='AKIAIOSFODNN7EXAMPLE'
readonly EXAMPLE_GITHUB_TOKEN='ghp_EXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPL0'

root="$(make_fixture release_body_credential)"
printf 'The fleet is live.\n\nPasted by mistake: %s\n' "$EXAMPLE_GITHUB_TOKEN" \
  > "${root}/.stub/release-body.txt"
run_release 'credential: a Release body carrying a GitHub token is refused' \
  1 'Release body contains a GitHub token' "$root" "$TARGET_VERSION"
run_release 'credential: the refusal says the tree was not written' \
  1 'Nothing has been written' "$root" "$TARGET_VERSION"
assert_case 'credential: a refused Release body leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"
assert_case 'credential: the Release-body refusal never echoes the matched token' \
  0 'driver named the category and not the credential' \
  bash "$NO_ECHO_CHECK" "$root" "$TARGET_VERSION" "$EXAMPLE_GITHUB_TOKEN"

# The contract, whose `documentation.*` fields are free prose, had no content
# check at all before this refusal existed.
root="$(make_fixture contract_credential)"
printf '%s\n' "$CONTRACT_JSON" \
  | sed -E "s|\"purpose\": \"[^\"]*\"|\"purpose\": \"deploy with ${EXAMPLE_AWS_KEY}\"|" \
  > "${root}/.stub/contract.json"
run_release 'credential: a contract carrying an AWS access-key ID is refused' \
  1 'contains an AWS access-key ID' "$root" "$TARGET_VERSION"
assert_case 'credential: a refused contract leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"
assert_case 'credential: the contract refusal never echoes the matched key' \
  0 'driver named the category and not the credential' \
  bash "$NO_ECHO_CHECK" "$root" "$TARGET_VERSION" "$EXAMPLE_AWS_KEY"

# The refusal is a SHAPE check, not an address check. This app sweeps the
# operator's LAN and its release notes say so, so a body naming a private-range
# subnet must still cut a release (DECISIONS.md entry 15).
root="$(make_fixture private_range_body_allowed)"
printf 'Miner Fleet %s\n\nSet MINER_FLEET_SUBNETS=192.168.1.0/24 in config.env on the box.\nThe health probe answers on 127.0.0.1 inside the container.\n' \
  "$TARGET_VERSION" > "${root}/.stub/release-body.txt"
run_release 'credential: a body naming a private-range subnet still releases' \
  0 'done' "$root" "$TARGET_VERSION"

# ---------------------------------------------------------------------------
# A REGISTRY THAT CANNOT ANSWER IS A HARD FAILURE, never a fall-through to a
# digest carried in from somewhere else.
# ---------------------------------------------------------------------------
root="$(make_fixture missing_image)"
touch "${root}/.stub/inspect.fail"
run_release 'digest: an unresolvable tag is a hard failure' 1 'imagetools inspect' \
  "$root" "$TARGET_VERSION"
assert_case 'digest: an unresolvable tag leaves the tree untouched' 0 'tree untouched' \
  bash "$UNTOUCHED_CHECK" "$root" "$TARGET_VERSION"

root="$(make_fixture no_top_level_digest)"
printf 'Name: %s:%s\n\nManifests:\n  Digest:    %s\n' \
  "$UPSTREAM_IMAGE" "$TARGET_VERSION" "$PLATFORM_DIGEST" > "${root}/.stub/inspect.out"
run_release 'digest: inspect output with no top-level Digest line fails closed' 1 'found 0' \
  "$root" "$TARGET_VERSION"

report_summary

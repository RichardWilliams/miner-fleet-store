#!/usr/bin/env bash
#
# sync-settings.sh — Regenerate <repo>/.claude/settings.json from the
# canonical hook-registrations fragment plus the per-repo
# settings.local-additions.json.
#
# Why this script exists (codespace#880):
#   Hook drift was confirmed across managed repos — workbench's
#   settings.json registered 21 of the codespace's 27 PreToolUse Bash
#   hooks even though the hook scripts themselves were present. The
#   spike (also #880) found that Claude Code's settings.json has no
#   native composition keyword (no extends/include/$import), so we
#   cannot have a managed repo's settings.json *reference* the codespace
#   canonical at runtime — we have to *generate* the file from a
#   canonical fragment at edit time and lock it against hand-edits.
#
# Inputs:
#   <repo>/.claude/canonical/hook-registrations.json
#       Canonical fragment containing the full hooks block. In the
#       codespace this is a real file. In every other managed repo it
#       is a per-file symlink to .engine-context/codespace/.claude/
#       canonical/hook-registrations.json so updates propagate without
#       a per-repo PR.
#   <repo>/.claude/settings.local-additions.json
#       Per-repo extras (permissions, env, etc.). The "hooks" key is
#       deliberately stripped from this input — only the canonical
#       fragment is allowed to register hooks.
#
# Output:
#   <repo>/.claude/settings.json
#       Generated artifact carrying:
#         _generator    one-line note pointing at the canonical fragment
#         _checksum     sha256 of the deterministic canonical+local input
#         hooks         from canonical fragment
#         <other keys>  from local-additions (sans "hooks")
#       Claude Code's loader silently ignores unknown top-level keys
#       (issue #880's spike confirmed this), so _generator and
#       _checksum are inert at runtime — they exist for the
#       lock/verify path only.
#
# Modes:
#   (default)        Generate the file. Idempotent — repeated runs
#                    produce byte-identical output for the same inputs.
#   --verify         Recompute and compare against the on-disk file.
#                    Exit non-zero if they differ. Used by the pre-commit
#                    hook and the CI job.
#
# Usage:
#   scripts/sync-settings.sh --repo <path>
#   scripts/sync-settings.sh --repo <path> --verify
#
# Exit codes:
#   0   success (generated, or verified-clean)
#   1   error (missing dependency, malformed input, verify-mismatch)
#   2   skipped (canonical fragment or local-additions absent — repo
#       has not been onboarded onto the generator yet)

set -euo pipefail
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Required-tool guards (CLI checks first per shell-script rules) ---
command -v jq >/dev/null || { echo "ERROR: jq not found" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "ERROR: sha256sum not found" >&2; exit 1; }

# The generate-mode write is the one atomic write, scripts/lib/atomic-write.sh.
# shellcheck source=lib/atomic-write.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/atomic-write.sh"

# --- Parse arguments ---
REPO=""
VERIFY=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -lt 2 ]] && { echo "ERROR: --repo requires a value" >&2; exit 1; }
      REPO="$2"; shift 2 ;;
    --verify) VERIFY=true; shift ;;
    -h|--help) SHOW_HELP=true; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if $SHOW_HELP; then
  cat <<'HELP'
sync-settings.sh — Regenerate .claude/settings.json from canonical inputs.

Usage:
  scripts/sync-settings.sh --repo <path>           # generate
  scripts/sync-settings.sh --repo <path> --verify  # check on-disk == regenerated

Inputs read from:
  <repo>/.claude/canonical/hook-registrations.json
  <repo>/.claude/settings.local-additions.json

Output written to:
  <repo>/.claude/settings.json

Exit codes:
  0  generated or verified-clean
  1  error or verify-mismatch
  2  skipped (canonical inputs absent — repo not onboarded)
HELP
  exit 0
fi

[[ -z "$REPO" ]] && { echo "ERROR: --repo <path> is required" >&2; exit 1; }
[[ -d "$REPO" ]] || { echo "ERROR: repo not found: $REPO" >&2; exit 1; }

# Resolve to an absolute, canonical path so error messages are unambiguous.
REPO=$(cd "$REPO" && pwd)

# --- Resolve inputs ---
canonical="$REPO/.claude/canonical/hook-registrations.json"
local_add="$REPO/.claude/settings.local-additions.json"
output="$REPO/.claude/settings.json"

if [[ ! -f "$canonical" ]]; then
  echo "skip: $canonical not found — repo not onboarded onto the generator" >&2
  exit 2
fi
if [[ ! -f "$local_add" ]]; then
  echo "skip: $local_add not found — repo not onboarded onto the generator" >&2
  exit 2
fi

# Validate JSON inputs early so the failure mode is "your input is bad",
# not "the regenerated file looks weird".
jq -e . "$canonical" >/dev/null 2>&1 || { echo "ERROR: $canonical is not valid JSON" >&2; exit 1; }
jq -e . "$local_add" >/dev/null 2>&1 || { echo "ERROR: $local_add is not valid JSON" >&2; exit 1; }

# --- Compute deterministic checksum ---
# jq -c emits compact JSON; concatenating the two compact streams gives
# an order-stable, whitespace-stable input to sha256sum so the same
# logical inputs always produce the same checksum regardless of how the
# source files were prettified.
checksum=$(
  {
    jq -cS . "$canonical"
    jq -cS . "$local_add"
  } | sha256sum | cut -d' ' -f1
)

# --- Build generated settings.json ---
# The header text is verbose by design — when an operator opens the file
# they should immediately see the canonical channel and the regenerate
# command without having to look anything up.
generator_note="GENERATED — do not edit by hand. Edit .claude/canonical/hook-registrations.json (canonical hooks) or .claude/settings.local-additions.json (per-repo extras), then run scripts/sync-settings.sh --repo <path>."

# del(.hooks) on local-additions enforces the canonical-only-controls-hooks
# rule structurally — even if a repo accidentally adds a "hooks" key to
# its local-additions, the generator strips it before merging.
generated=$(
  jq -n \
    --arg gen "$generator_note" \
    --arg cks "sha256:$checksum" \
    --slurpfile h "$canonical" \
    --slurpfile l "$local_add" \
    '{
      _generator: $gen,
      _checksum: $cks,
      hooks: $h[0]
    } + ($l[0] | del(.hooks))'
)

# --- Verify mode: compare on-disk against regenerated ---
if $VERIFY; then
  if [[ ! -f "$output" ]]; then
    echo "ERROR: $output does not exist; run without --verify to generate" >&2
    exit 1
  fi
  current=$(cat "$output")
  if [[ "$generated" != "$current" ]]; then
    {
      echo "ERROR: $output is out of sync with canonical inputs."
      echo ""
      echo "Regenerate with:"
      echo "  scripts/sync-settings.sh --repo $REPO"
      echo ""
      echo "First lines of diff (current vs regenerated):"
      diff <(printf '%s\n' "$current") <(printf '%s\n' "$generated") | head -30
    } >&2
    exit 1
  fi
  echo "OK: $output is in sync with canonical inputs."
  exit 0
fi

# --- Generate mode: write atomically ---
# A temporary file beside settings.json is renamed over it, so a failed or
# interrupted write leaves the old file intact. An existing settings.json keeps
# its mode; a new one gets 0666 less the umask.
write_file_atomically "$output" - "${generated}"$'\n' || exit 1
echo "Generated $output (sha256:$checksum)"

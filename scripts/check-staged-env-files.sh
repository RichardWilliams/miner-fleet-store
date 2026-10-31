#!/usr/bin/env bash
# check-staged-env-files.sh — refuse a commit that stages an env-secrets
# file under ANY letter case (cs#1815).
#
# Why a commit-time guard: gitignore has no per-pattern case control. Under
# `core.ignorecase=true` — git's default on a case-insensitive filesystem —
# the canonical baseline's `!.env.example` negation un-ignores EVERY case
# variant of that name, so `.ENV.EXAMPLE` or `.Env.Example` holding real
# values escapes the `.env` / `.env.*` block. Case is this guard's; depth
# (root-anchoring the negations) is the ignore file's (cs#1814).
#
# The rule, defined ONCE in `is_env_secret_basename` below: a path is
# refused when its BASENAME, compared case-insensitively, is `.env`,
# `.env.<anything>`, or `<anything>.env` — except a basename byte-equal to
# the lowercase `.env.example`, which holds placeholders only. The
# `<anything>.env` shape is in the set because it is a live secrets shape
# in this estate (`.devcontainer/devcontainer.env`).
#
# Which paths are inspected:
#   default       — every staged path except a deletion:
#                   `git diff --cached --name-only -z --diff-filter=d`.
#                   The lowercase `d` EXCLUDES deletions and selects every
#                   other status, so a type change (`T` — a tracked symlink
#                   at `.env` replaced by a regular file holding values) is
#                   inspected like any addition; an allowlist of statuses
#                   (`ACMR`) silently missed it. A DELETION is never
#                   inspected, so removing a legacy
#                   `.ENV.local` is never blocked. A RENAME is inspected at
#                   its DESTINATION only: the source leaves the tree, like
#                   a deletion, so renaming a case-variant file to a safe
#                   name is never blocked, while renaming anything INTO a
#                   refused name is.
#   --tree <rev>  — every path tracked in <rev> (`git ls-tree -r`), for
#                   auditing a repo that already carries such a file.
#
# Called by `.githooks/pre-commit`. Standalone:
#   bash scripts/check-staged-env-files.sh --repo-root <path> [--tree <rev>]
#
# Only PATHS are printed — never file content.
#
# Exit codes:
#   0 — no refused path
#   1 — one or more refused paths (listed on stderr), a usage error, or a
#       path listing git could not produce (named on stderr): a listing
#       that failed is never read as "no refused path" (cs#2011)

set -euo pipefail
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Required CLI guards ---
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found" >&2; exit 1; }

usage() {
  sed -n '2,/^[^#]/{ /^#/s/^# \{0,1\}//p; }' "$0"
}

REPO_ROOT=""
TREE_REV=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      [[ $# -ge 2 ]] || { echo "ERROR: --repo-root requires a path" >&2; exit 1; }
      REPO_ROOT="$2"; shift 2 ;;
    --tree)
      [[ $# -ge 2 ]] || { echo "ERROR: --tree requires a revision" >&2; exit 1; }
      TREE_REV="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$REPO_ROOT" ]] || { echo "ERROR: --repo-root <path> is required" >&2; exit 1; }

# --- Git work-tree guard ---
git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "ERROR: not a git work tree: ${REPO_ROOT}" >&2; exit 1; }

# Exit 0 iff the basename is an env-secrets shape this guard refuses. The
# exception is compared case-SENSITIVELY, the shapes case-insensitively;
# `nocasematch` is switched on for the shape test alone.
is_env_secret_basename() {
  local name="$1" refused=1
  if [[ "$name" == ".env.example" ]]; then
    return 1
  fi
  shopt -s nocasematch
  if [[ "$name" == ".env" || "$name" == .env.* || "$name" == *.env ]]; then
    refused=0
  fi
  shopt -u nocasematch
  return "$refused"
}

# The listing goes to a temp file and its status is taken where git runs, never
# read back from a process substitution after the read, where bash did not
# reliably return it (cs#1993, cs#2012).
if ! listing="$(mktemp)"; then
  echo "ERROR: cannot create a temp file for the paths of ${REPO_ROOT}; nothing was checked." >&2
  exit 1
fi
trap 'rm -f -- "$listing"' EXIT
if [[ -n "$TREE_REV" ]]; then
  if ! git -C "$REPO_ROOT" ls-tree -r -z --name-only "$TREE_REV" >"$listing"; then
    echo "ERROR: cannot list the paths tracked in ${TREE_REV} (git failed above); nothing was checked." >&2
    exit 1
  fi
elif ! git -C "$REPO_ROOT" diff --cached --name-only -z --diff-filter=d >"$listing"; then
  echo "ERROR: cannot list the staged paths of ${REPO_ROOT} (git failed above); nothing was checked." >&2
  exit 1
fi
declare -a refused=()
while IFS= read -r -d '' path; do
  if is_env_secret_basename "${path##*/}"; then
    refused+=("$path")
  fi
done <"$listing"

if [[ "${#refused[@]}" -eq 0 ]]; then
  exit 0
fi

if [[ -n "$TREE_REV" ]]; then
  echo "ERROR: ${TREE_REV} tracks env-secrets file(s) under a letter case gitignore cannot block:" >&2
else
  echo "ERROR: staged env-secrets file(s) — refusing the commit:" >&2
fi
for path in "${refused[@]}"; do
  printf '  %q\n' "$path" >&2
done
cat >&2 <<'MSG'

A basename of .env, .env.<anything> or <anything>.env is refused in ANY
letter case. The one exception is the lowercase .env.example, which must
hold placeholders only.

  - A secrets file: unstage it (git restore --staged <path>) and keep it
    out of version control.
  - A placeholder file: name it exactly .env.example (lowercase).

To bypass (genuine emergency only): ALLOW_HOOK_BYPASS=1 git commit --no-verify
(and add the justification in the commit message).
MSG
exit 1

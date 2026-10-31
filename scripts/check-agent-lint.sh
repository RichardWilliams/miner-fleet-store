#!/usr/bin/env bash
# check-agent-lint.sh — lint agent files for common anti-patterns.
#
# Scans .claude/agents/*.md files for:
#   1. Hardcoded package manager commands — agents must use package-manager-
#      agnostic language rather than hardcoding npm, yarn, pnpm, or bun.
#   2. Meta-syntax in output templates — angle-bracket placeholders such as
#      <name> or <placeholder> in prose or prompt templates. Known HTML tags
#      and frontmatter delimiters are excluded.
#
# Both rules skip lines inside fenced code blocks — example output is
# display, not directive, so pinned package managers inside ```...``` blocks
# do not produce findings.
#
# Usage:
#   scripts/check-agent-lint.sh [--repo-root <path>] [--files <file>...]
#
# Arguments:
#   --repo-root <path>  Repository root (default: the repo this script sits
#                       in, <repo>/scripts/, never the caller's cwd; cs#2015)
#   --files <file>...   Specific files to check (default: every regular file
#                       .claude/agents/*.md; a symlinked agent is a canonical
#                       one, a regular file in the codespace and linted there;
#                       cs#2015)
#
# Environment variable overrides:
#   CHECK_AGENT_REPO_ROOT — repository root override
#
# Exit codes:
#   0 — no anti-patterns found
#   1 — one or more anti-patterns detected, or an error named on stderr
#       (a usage error, or an agent-file listing that failed), or a line a
#       check could not scan, named as `file:line: ERROR:` on stdout

set -euo pipefail
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Required CLI guards ---
command -v git >/dev/null || { echo "ERROR: git not found" >&2; exit 1; }
command -v grep >/dev/null || { echo "ERROR: grep not found" >&2; exit 1; }

# --- Parse arguments ---
REPO_ROOT_ARG=""
SHOW_HELP=false
declare -a FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      [[ $# -lt 2 ]] && { echo "ERROR: --repo-root requires a value" >&2; exit 1; }
      REPO_ROOT_ARG="$2"; shift 2 ;;
    --files)
      shift
      while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
        FILES+=("$1"); shift
      done
      ;;
    --help) SHOW_HELP=true; shift ;;
    -*) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    *)  echo "ERROR: unexpected argument: $1" >&2; exit 1 ;;
  esac
done

if [[ "$SHOW_HELP" == true ]]; then
  sed -n '2,/^[^#]/{ /^#/s/^# \{0,1\}//p; }' "$0"
  exit 0
fi

# --- Determine repo root ---
if [[ -n "$REPO_ROOT_ARG" ]]; then
  [[ -d "$REPO_ROOT_ARG" ]] || { echo "ERROR: --repo-root directory does not exist: $REPO_ROOT_ARG" >&2; exit 1; }
  REPO_ROOT="$REPO_ROOT_ARG"
elif [[ -n "${CHECK_AGENT_REPO_ROOT:-}" ]]; then
  [[ -d "$CHECK_AGENT_REPO_ROOT" ]] || { echo "ERROR: CHECK_AGENT_REPO_ROOT directory does not exist: $CHECK_AGENT_REPO_ROOT" >&2; exit 1; }
  REPO_ROOT="$CHECK_AGENT_REPO_ROOT"
else
  # Default: the repo this script sits in, <repo>/scripts/, taken as the
  # parent of its directory (cs#2015). Git's toplevel asked from that
  # directory would be wrong inside a hook, whose exported GIT_DIR makes git
  # take the cwd as the work tree. No sourced helper can supply the root: the
  # work-tree guard that needs it precedes every required-file read
  # (CLAUDE.md § Shell Script Rules; bootstrap ordering,
  # docs/hook-standards.md § 4.1).
  if ! REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; then
    echo "ERROR: cannot resolve the repo holding ${BASH_SOURCE[0]}" >&2; exit 1
  fi
  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: ${REPO_ROOT} is not inside a git work tree. Use --repo-root to specify." >&2; exit 1; }
fi

# --- Collect agent files to check ---
AGENTS_DIR="${REPO_ROOT}/.claude/agents"

if [[ ${#FILES[@]} -eq 0 ]]; then
  [[ -d "$AGENTS_DIR" ]] || { echo "No agents directory found at .claude/agents/ — nothing to lint."; exit 0; }
  # The listing goes to a temp file and its status is taken where it runs,
  # never read back from a process substitution after the read, where bash did
  # not reliably return it (cs#1993, cs#2012). Under pipefail that status is
  # find's failure, not sort's success.
  if ! listing="$(mktemp)"; then
    echo "ERROR: cannot create a temp file for the agent files in ${AGENTS_DIR}; nothing was linted." >&2
    exit 1
  fi
  trap 'rm -f -- "$listing"' EXIT
  if ! find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' -print0 | sort -z >"$listing"; then
    echo "ERROR: cannot list the agent files in ${AGENTS_DIR} (find failed above); nothing was linted." >&2
    exit 1
  fi
  while IFS= read -r -d '' f; do
    FILES+=("$f")
  done <"$listing"
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No regular agent files in .claude/agents/ — nothing to lint."
  exit 0
fi

# --- Check runner ---
FINDINGS=0
# Lines a check could not read; any one of them means no verdict is given.
ERRORS=0

# _grep_error <file-label> <line-number> <status> — name a line grep could not
# scan (#1969): grep exits 1 for no match, and any other non-zero status means
# it did not run to an answer, which is never read as "no match".
_grep_error() {
  printf '%s:%s: ERROR: grep exited %s; this line was not checked\n' "$1" "$2" "$3"
  ERRORS=$((ERRORS + 1))
}

# _prose_lines <abs-filepath> <array-name>
# Fill <array-name> with one "<line-number><TAB><line>" entry for each line of
# the file that is prose: not blank, not a ``` fence marker, and not inside a
# fenced code block. A fenced block holds example output, not agent
# instructions, so both checks below read only these lines; reading them from
# one definition keeps the two checks agreeing on what a fence is (cs#2015).
# A file that cannot be read fails the redirect, as it did in each check.
_prose_lines() {
  local filepath="$1"
  local -n _prose_out="$2"
  local in_code_fence=false
  local line_num=0
  local line
  _prose_out=()
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # Skip blank lines
    [[ -z "${line// /}" ]] && continue

    # Toggle code fence state and skip the fence-marker line itself
    if [[ "$line" =~ ^[[:space:]]*\`\`\` ]]; then
      if [[ "$in_code_fence" == true ]]; then
        in_code_fence=false
      else
        in_code_fence=true
      fi
      continue
    fi

    # Skip lines inside code fences
    [[ "$in_code_fence" == true ]] && continue

    _prose_out+=("${line_num}"$'\t'"${line}")
  done < "$filepath"
}

# check_package_manager <file-label> <abs-filepath>
# Scans for hardcoded package manager commands and prints findings in the
# required format: file:line: PACKAGE_MGR: hardcoded <command> found
check_package_manager() {
  local file="$1"
  local filepath="$2"

  [[ -f "$filepath" ]] || return 0

  # Pattern: a PM tool name immediately followed by a known subcommand.
  # This catches command invocations (e.g. "npm install", "yarn run build")
  # without flagging prose mentions like "npm package" or "detect npm".
  #
  # Subcommands covered: install add run ci build test start dev exec
  #                      create init remove uninstall update upgrade publish
  #
  # POSIX ERE, the dialect bash's `=~` parses: the word boundaries are a
  # non-word character or the line's edge, never the PCRE `\b` (cs#2015).
  # Group 2 is the command itself, without the boundary characters.
  local pm_pattern='(^|[^[:alnum:]_])((npm|yarn|pnpm|bun)[[:space:]]+(install|add|run|ci|build|test|start|dev|exec|create|init|remove|uninstall|update|upgrade|publish))([^[:alnum:]_]|$)'

  # Only prose lines (_prose_lines): a command shown for illustration in a
  # fenced block is not a hardcoded directive.
  local -a prose=()
  _prose_lines "$filepath" prose
  local entry line_num line
  for entry in "${prose[@]}"; do
    line_num="${entry%%$'\t'*}"
    line="${entry#*$'\t'}"

    if [[ "$line" =~ $pm_pattern ]]; then
      printf '%s:%s: PACKAGE_MGR: hardcoded %s found\n' "$file" "$line_num" "${BASH_REMATCH[2]}"
      FINDINGS=$((FINDINGS + 1))
    fi
  done
}

# check_meta_syntax <file-label> <abs-filepath>
# Scans for angle-bracket placeholder patterns (e.g. <name>, <placeholder>) and
# prints findings in the required format:
#   file:line: META_SYNTAX: angle-bracket placeholder found: <name>
# A line grep could not scan is an ERROR (`_grep_error`), never "no match".
#
# Skips:
#   - Known HTML tags (case-insensitive)
#   - Lines inside code fences (``` ... ```)
#   - Frontmatter delimiter lines (starting with ---)
check_meta_syntax() {
  local file="$1"
  local filepath="$2"

  [[ -f "$filepath" ]] || return 0

  # Known safe HTML/XML tags — matched case-insensitively.
  # Closing tags (</tag>) share the same name after stripping punctuation.
  local -a html_tags=(
    a abbr acronym address article aside audio b blockquote body br button
    caption cite code col colgroup data datalist dd del details dfn dialog
    div dl dt em embed fieldset figcaption figure footer form h1 h2 h3 h4
    h5 h6 head header hr html i iframe img input ins kbd label legend li
    link main map mark menu meta meter nav noscript object ol optgroup
    option output p param picture pre progress q rp rt ruby s samp script
    section select small source span strong style sub summary sup table
    tbody td template textarea tfoot th thead time title tr track u ul
    var video wbr
    # Reviewer-agent canonical placeholders. These are NOT HTML tags but
    # are intentionally bare in agent documentation: `workbench-output` is
    # the wrapper marker every reviewer emits its JSON envelope inside;
    # `agent-name`, `relative-path`, `number` are example placeholders in
    # documentation showing what an agent should produce. Exempting them
    # keeps the lint focused on accidental angle-bracket prose tokens
    # (the original target of the META_SYNTAX rule).
    workbench-output agent-name relative-path number
  )

  # Build a pipe-delimited alternation pattern for the safe tag check
  local safe_pattern
  safe_pattern="$(IFS='|'; echo "${html_tags[*]}")"

  local -a prose=()
  _prose_lines "$filepath" prose
  local entry line_num line status
  for entry in "${prose[@]}"; do
    line_num="${entry%%$'\t'*}"
    line="${entry#*$'\t'}"

    # Skip frontmatter delimiter lines
    [[ "$line" =~ ^--- ]] && continue

    # Strip inline code spans (`...`) before scanning — STANDARDS.md permits
    # angle-bracket placeholders in agent file examples when wrapped in
    # backticks. A sed pass with a non-greedy equivalent removes the spans.
    # Backticks are matched as literal characters via the printf-built
    # pattern so no shell expansion happens inside the regex string.
    local stripped_line backtick_pattern
    backtick_pattern="$(printf '%s[^%s]*%s' '`' '`' '`')//g"
    stripped_line="$(printf '%s' "$line" | sed -E "s/${backtick_pattern}")"

    # Extract all angle-bracket tokens: <tag>, </tag>, <tag/> forms
    local all_matches
    status=0
    all_matches="$(grep -oE '</?[A-Za-z][A-Za-z0-9_-]*/?>' <<< "$stripped_line")" || status=$?
    case "$status" in
      0) ;;
      1) continue ;;
      *) _grep_error "$file" "$line_num" "$status"; continue ;;
    esac

    while IFS= read -r match; do
      [[ -z "$match" ]] && continue
      # Strip punctuation to get the bare tag name, then lowercase it
      local tag_name
      tag_name="$(printf '%s' "$match" | tr -d '<>/?' | tr '[:upper:]' '[:lower:]')"
      # Skip if it is a known HTML tag
      status=0
      grep -qE "^(${safe_pattern})$" <<< "$tag_name" || status=$?
      case "$status" in
        0) continue ;;
        1) ;;
        *) _grep_error "$file" "$line_num" "$status"; continue ;;
      esac
      printf '%s:%s: META_SYNTAX: angle-bracket placeholder found: %s\n' "$file" "$line_num" "$match"
      FINDINGS=$((FINDINGS + 1))
    done <<< "$all_matches"
  done
}

echo "Linting agent files for common anti-patterns..."
echo ""

for file in "${FILES[@]}"; do
  abs_path=""
  if [[ "$file" = /* ]]; then
    abs_path="$file"
    # Produce a relative-style label for output readability
    file=".claude/agents/$(basename "$file")"
  else
    abs_path="${REPO_ROOT}/${file}"
  fi

  [[ -f "$abs_path" ]] || continue

  # --- Check 1: Hardcoded package manager commands ---
  check_package_manager "$file" "$abs_path"

  # --- Check 2: Meta-syntax in output templates ---
  check_meta_syntax "$file" "$abs_path"
done

# --- Summary ---
echo ""
if [[ "$ERRORS" -gt 0 ]]; then
  echo "Agent lint could not check ${ERRORS} line(s) (the ERROR lines above); no verdict is given." >&2
  exit 1
fi
if [[ "$FINDINGS" -eq 0 ]]; then
  echo "No agent anti-patterns found in ${#FILES[@]} file(s)."
  exit 0
else
  echo "Agent lint found ${FINDINGS} anti-pattern(s) in ${#FILES[@]} file(s)." >&2
  exit 1
fi

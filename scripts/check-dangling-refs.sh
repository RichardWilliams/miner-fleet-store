#!/usr/bin/env bash
# check-dangling-refs.sh — scan tracked text files for references to files
# being deleted in this commit. Catches dangling agent/doc cross-references
# before they enter the review cycle. The files scanned, and the content read,
# are the index's: what this commit records, never the working tree, which can
# hold gitignored or untracked files and unstaged edits (cs#2007).
#
# Called automatically by the pre-commit hook.
# Can also be run standalone, from any directory:
#   <repo>/scripts/check-dangling-refs.sh
# The repo checked is the one this script sits in (<repo>/scripts/), never
# the caller's cwd: every git call names it with -C (cs#2015).
#
# Environment variable overrides:
#   MIN_TERM_LEN  — minimum character length for a search term (default: 4)
#
# Exit codes:
#   0 — no dangling references found (or no files being deleted)
#   1 — dangling references detected (details printed to stdout), or an
#       error named on stderr: a staged-deletion listing, candidate listing or
#       committed-content read that failed is never read as an empty one
#       (cs#2011, cs#2007)

# `mapfile -d ''`, which reads the NUL-separated term matches below, needs
# Bash 4.4+; an older bash cannot run this check.
if (( BASH_VERSINFO[0] < 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4 ) )); then
  echo "ERROR: Bash 4.4+ required (mapfile -d). On macOS: brew install bash" >&2; exit 1
fi

set -euo pipefail
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Required CLI guards ---
command -v git >/dev/null 2>&1  || { echo "ERROR: git not found" >&2; exit 1; }
command -v grep >/dev/null 2>&1 || { echo "ERROR: grep not found" >&2; exit 1; }
command -v mktemp >/dev/null 2>&1 || { echo "ERROR: mktemp not found" >&2; exit 1; }

# --- Git work-tree guard ---
# The repo is named from this script's place in it, <repo>/scripts/: the parent of the
# directory this script sits in, never `git rev-parse --show-toplevel` run
# there: inside a git hook git exports GIT_DIR, and git then takes the cwd as
# the work tree, so that read would answer the script's own directory.
# It is derived here and not by a sourced helper (bootstrap ordering,
# docs/hook-standards.md § 4.1): the work-tree guard below needs it, and
# CLAUDE.md § Shell Script Rules puts that guard before any required-file
# read, sourcing a helper included.
if ! REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; then
  echo "ERROR: cannot resolve the repo holding ${BASH_SOURCE[0]}" >&2; exit 1
fi
git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "ERROR: ${REPO_ROOT} is not inside a git work tree" >&2; exit 1; }

# Each listing below whose failure would shrink what is checked is written to
# `listing` and its status taken where it runs, never read back from a process
# substitution after the read, where bash did not reliably return it (cs#1993,
# cs#2012). The tracked-path and staged-path listings fail only toward checking
# more. git grep's stderr goes to `grep_err` (see fail_on_grep_error).
if ! listing="$(mktemp)" || ! grep_err="$(mktemp)"; then
  echo "ERROR: cannot create the temp files this check reads its listings from; nothing was checked." >&2
  [[ -z "${listing:-}" ]] || rm -f -- "$listing"
  exit 1
fi
trap 'rm -f -- "$listing" "$grep_err"' EXIT

# Minimum stem length — single-character or very short names cause too many false positives
MIN_TERM_LEN="${MIN_TERM_LEN:-4}"

# --- Get staged deletions ---
# `git rm --cached <f>` (untrack — file kept on disk) and a true deletion BOTH
# surface as a `D` under --diff-filter=D, but they are not the same thing: a
# reference to a file that still exists on disk is not dangling. Exclude any
# staged-`D` path that is still present in the working tree, so only files that
# are genuinely gone can flag a reference. (cs#1476: untracking
# .claude/settings.json into a gitignored generated artifact false-fired this
# check against ~30 docs/scripts merely mentioning the word "settings".)
declare -a deleted_files=()
if ! git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=D >"$listing"; then
  echo "ERROR: cannot list the staged deletions (git failed above); nothing was checked." >&2
  exit 1
fi
while IFS= read -r del_path; do
  [[ -z "$del_path" ]] && continue
  [[ -e "$REPO_ROOT/$del_path" ]] && continue   # untracked-but-present, not deleted
  deleted_files+=("$del_path")
done <"$listing"

if [[ "${#deleted_files[@]}" -eq 0 ]]; then
  exit 0
fi

# --- What still resolves after this commit (cs#1995) ---
# A name a deleted file shares with a surviving tracked file is not dangling:
# deleting one of several README.md files leaves "README.md" naming the others.
# The index IS the post-commit tree (staged deletions are already out of it), so
# its paths are what a reference can still resolve to. Before this, deleting
# one image directory's Dockerfile and README.md flagged every "Dockerfile" and
# "README" mention in the repo.
#
# This is decided from tracked state, never from a declared list of names or
# references; that kind of exemption mechanism was refused under cs#1857. A
# listing that comes back empty skips nothing, so every term is searched.
declare -A surviving_basenames=()
declare -a surviving_paths=()
while IFS= read -r -d '' tracked_path; do
  surviving_basenames["${tracked_path##*/}"]=1
  surviving_paths+=("$tracked_path")
done < <(git -C "$REPO_ROOT" ls-files -z)

# True when <term>, a path suffix such as `<parent>/<filename>`, still names a
# surviving tracked path: the path equals it or ends in `/<term>`.
path_term_resolves() {
  local term="$1" surviving
  for surviving in "${surviving_paths[@]}"; do
    if [[ "$surviving" == "$term" || "$surviving" == */"$term" ]]; then
      return 0
    fi
  done
  return 1
}

# --- Staged files are the author's active edits in THIS commit (cs#1407) ---
# A reference to a deleted file inside a file the author is editing in the
# same commit is intentional, not a stale dangling reference. This check
# exists to catch references in files the author DID NOT touch — a
# pre-existing doc/config left pointing at a now-deleted file. The cs#1407
# receipt: deleting `marker_target.py` while documenting its retirement in
# DECISIONS.md + INVARIANTS.md and asserting its absence in an exp-006 test
# (all staged in the same deletion commit) false-fired this check. Excluding
# staged files removes that false positive while preserving the catch on
# untouched files (covered by exp-003/exp-004 below).
declare -A staged_set
while IFS= read -r staged_path; do
  [[ -n "$staged_path" ]] && staged_set["$staged_path"]=1
done < <(git -C "$REPO_ROOT" diff --cached --name-only)

# --- Build search terms from deleted file stems ---
# We search for the basename-without-extension (the "stem") of each deleted
# file. Using just the stem means a single search catches all reference styles:
#   shop-engineer       (bare agent name in prose)
#   shop-engineer.md    (path reference in JSON or docs)
# If a stem is shorter than MIN_TERM_LEN characters it is skipped to avoid
# trivially common false positives.
# search term -> originating deleted path. Initialised empty, because any
# term can be skipped (a short stem, or a name that still resolves) and an
# empty count must still read under `set -u`.
declare -A term_to_source=()

# Add <deleted_file>'s shortest unique path suffix as a search term (cs#1995).
# Starting from `<parent>/<filename>`, one parent directory is prepended at a
# time until no surviving tracked path resolves the suffix: deleting
# `a/x/README.md` while `b/x/README.md` survives searches `a/x/README.md`. `/`
# is a boundary character in the match below, so the suffix also matches every
# longer form of the reference, the full repo-relative path included. When even
# the full path resolves, because it is the tail of a surviving path (a
# repo-root file whose basename survives in any directory, or `a/x/README.md`
# while `z/a/x/README.md` survives), every path form of the reference also
# names that survivor, and no path term is added. A repo-root file has no
# `<parent>/` form, so it never adds one and is searched by its bare-name
# terms alone.
add_path_term() {
  local deleted="$1" rest="$1" suffix="${1##*/}"
  while [[ "$rest" == */* ]]; do
    rest="${rest%/*}"
    suffix="${rest##*/}/${suffix}"
    if ! path_term_resolves "$suffix"; then
      term_to_source["$suffix"]="$deleted"
      return 0
    fi
  done
}

# Add the command-invocation form `/<stem>` for a deleted file under
# `.claude/commands/` or `.claude/agents/` (callers reach this only for a stem
# of at least MIN_TERM_LEN characters). It is added whatever survives: a
# surviving file of the same name does not exempt it, so deleting
# `.claude/commands/<stem>.md` while `.claude/agents/<stem>.md` survives still
# searches `/<stem>` (cs#1995).
add_command_term() {
  local deleted="$1" stem="$2"
  case "$deleted" in
    *.claude/commands/*|*.claude/agents/*)
      term_to_source["/${stem}"]="$deleted"
      ;;
  esac
}

# cs#1575 — stems that are ordinary English words. `MIN_TERM_LEN` filters by
# LENGTH only, so a common word of length >= MIN_TERM_LEN passes it and then
# matches every prose sentence containing that word. Deleting
# `.claude/commands/review.md` produced the stem `review`, which matched
# "review" / "reviewer" / "review-cycle" prose across every reviewer-agent
# file — hundreds of hits, none of them a reference to the deleted command.
#
# For these stems the BARE-STEM term is not searched at all. The structured
# reference forms below are searched instead, so a genuine reference is still
# caught while the English word in prose is not. This list is a GUARD on the
# bare-stem match, never a way to stop checking a file: a deleted file still
# contributes each reference form that no surviving file resolves (cs#1995;
# `add_path_term` states the one case in which that leaves no path form).
COMMON_WORD_STEMS=" build check config create delete index list main merge \
review run search setup start state test update view "

for deleted_file in "${deleted_files[@]}"; do
  filename="${deleted_file##*/}"   # basename
  stem="${filename%.*}"            # strip extension

  if [[ "${#stem}" -lt "$MIN_TERM_LEN" ]]; then
    continue
  fi

  if [[ "$COMMON_WORD_STEMS" == *" ${stem} "* ]]; then
    # Structured reference forms ONLY — the shapes a real reference takes,
    # none of which appear in an English sentence using the word.
    #
    #   review.md           — a MANIFEST.json `canonical` entry, a doc link
    #   commands/review.md  — a path reference: the deleted file's shortest
    #                         path suffix no surviving path resolves (see
    #                         `add_path_term`). It also matches inside the full
    #                         repo-relative path, since `/` is a boundary
    #                         character, so no separate full-path term
    #   /review             — the command-invocation form. The shared
    #                         `[^[:alnum:]_-]` boundary applied below excludes
    #                         a longer sibling by construction: in
    #                         `/review-retrospective` the character after
    #                         `review` is `-`, which the boundary class
    #                         rejects, so the longer command does not match.
    #
    # The basename term is skipped when a surviving file carries the same
    # basename; the path term only when a surviving path ends in the deleted
    # file's whole repo-relative path (a repo-root file has no path term). The
    # command-invocation term is added whatever survives (`add_command_term`).
    if [[ "$filename" != "$stem" && -z "${surviving_basenames[$filename]:-}" ]]; then
      term_to_source["$filename"]="$deleted_file"
    fi
    add_path_term "$deleted_file"
    add_command_term "$deleted_file" "$stem"
  else
    # Every non-common stem: the bare stem already subsumes the forms above
    # (`shop-engineer` matches `shop-engineer.md` too), so adding them here
    # would report the same line several times. When a surviving file
    # carries the deleted file's basename, the bare name still resolves
    # (cs#1995), so the path reference is searched in its place, as the
    # shortest path suffix no surviving path resolves (`add_path_term`):
    # deleting `a/x/README.md` while `b/x/README.md` survives searches
    # `a/x/README.md`, and the command-invocation form (`add_command_term`),
    # which the bare stem would otherwise have matched. Deleting the last file
    # of a basename still searches the bare stem.
    if [[ -z "${surviving_basenames[$filename]:-}" ]]; then
      term_to_source["$stem"]="$deleted_file"
    else
      add_path_term "$deleted_file"
      add_command_term "$deleted_file" "$stem"
    fi
  fi
done

if [[ "${#term_to_source[@]}" -eq 0 ]]; then
  exit 0
fi

# --- Collect candidate files to scan ---
# Every tracked .md, .sh, .json and .txt file in the index, which is the tree
# this commit records (cs#2007). Gitignored and untracked files (an
# `.engine-context/` snapshot, a scratch note) are not part of the commit, so
# a reference in one is not dangling in it. A listing that fails is an error:
# a partial candidate list would report no dangling reference for the files
# it never read (cs#2011).
declare -a CANDIDATE_PATHSPECS=('*.md' '*.sh' '*.json' '*.txt')
declare -A candidate_set=()
if ! git -C "$REPO_ROOT" ls-files -z -- "${CANDIDATE_PATHSPECS[@]}" >"$listing"; then
  echo "ERROR: cannot list the candidate files in the index (git ls-files failed above); a partial scan proves nothing." >&2
  exit 1
fi
while IFS= read -r -d '' candidate_rel; do
  # Skip files staged in this commit — the author's active edits (cs#1407).
  [[ -n "${staged_set[$candidate_rel]:-}" ]] && continue
  candidate_set["$candidate_rel"]=1
done <"$listing"

# --- Scan for dangling references ---
FAILED=0

echo "Checking for dangling references to deleted files..."
echo ""

# Each term is searched in the committed content of every candidate with ONE
# `git grep --cached -l`, then each matching candidate's lines are read the
# same way. A blob git cannot read is NOT reported by git grep's exit status:
# it writes `error: '<path>': unable to read <sha>` and still exits 1, the
# status it gives "no match". So git grep's stderr decides: any line it writes
# there that is not a `warning:` is an error, never "no reference", whatever
# its exit status. A `warning:` (an unreadable worktree `.gitattributes`, which
# git grep consults even for `--cached`) changes no match `-l` / `-n` report
# here, and is passed through. Any exit status other than 0 or 1 is an error.

# Fail the check, naming <what>, when git grep's last run reported an error.
fail_on_grep_error() {
  local what="$1" rc="$2" filter_rc=0
  cat -- "$grep_err" >&2
  # 0: a line that is not a warning; 1: only warnings, or nothing; 2: unreadable.
  grep -qv '^warning: ' -- "$grep_err" || filter_rc=$?
  if [[ "$filter_rc" -ne 1 || "$rc" -gt 1 ]]; then
    echo "ERROR: cannot read the committed content ${what} (git grep exit ${rc}); a partial scan proves nothing." >&2
    exit 1
  fi
}
#
# Use word-boundary ERE (grep -E) so the stem must appear as a standalone
# token: `evidence-path` in prose matches, but `evidence-path-extended`
# (stem is a prefix of a longer identifier) and `pre-evidence-path` (stem
# is a suffix) do not. The boundary character class `[^[:alnum:]_-]`
# is the correct choice for kebab-case identifiers — hyphens inside the
# stem are part of the token; hyphens outside are boundaries.
#
# Bracketed-placeholder exemption (cs#1170): lines that match only because
# the stem appears as `<stem>` (angle-bracket documentation placeholder)
# are filtered out. The exemption applies when every occurrence on the
# matching line is surrounded by `<` + `>`, backtick + angle brackets, or
# similar documentation shapes. Implementation: after word-boundary grep,
# strip lines where the stem only occurs inside `<...>` wrappers by
# checking that at least one non-placeholder occurrence is present.
for term in "${!term_to_source[@]}"; do
  boundary='(^|[^[:alnum:]_-])'
  # Escape ERE metacharacters in $term so that stems containing dots
  # (e.g. `scan-cross-repo-stale.test` from `scan-cross-repo-stale.test.sh`)
  # do not produce patterns where `.` matches any character. The bracket
  # class `[].[()*^$+?{}|\\]` covers all ERE special characters; `]` and `[`
  # appear first/last in the class to be treated literally (POSIX bracket rule).
  term_esc=$(printf '%s' "$term" | sed 's/[].[()*^$+?{}|\\]/\\&/g')
  pattern="${boundary}${term_esc}([^[:alnum:]_-]|\$)"

  declare -a matched_files=()
  if git -C "$REPO_ROOT" grep --cached -l -z -E -e "$pattern" -- "${CANDIDATE_PATHSPECS[@]}" >"$listing" 2>"$grep_err"; then
    grep_rc=0
  else
    grep_rc=$?
  fi
  fail_on_grep_error "searched for '${term}'" "$grep_rc"
  mapfile -d '' -t matched_files <"$listing"

  for candidate_rel in "${matched_files[@]}"; do
    [[ -z "${candidate_set[$candidate_rel]:-}" ]] && continue
    if raw_matches="$(git -C "$REPO_ROOT" grep --cached -h -n -E -e "$pattern" -- ":(literal)${candidate_rel}" 2>"$grep_err")"; then
      grep_rc=0
    else
      grep_rc=$?
    fi
    fail_on_grep_error "of ${candidate_rel}" "$grep_rc"

    # Filter out lines where every occurrence of the stem is a bracketed
    # placeholder shape: `<stem>`, `` `<stem>` ``, `*<stem>*`, `[<stem>]`.
    # Keep lines where the stem is NOT exclusively inside `<...>`.
    matches=""
    while IFS= read -r line; do
      # Strip all `<stem>` occurrences from the line. If the stem still
      # appears in the stripped line (word-boundary match), it is a real
      # reference and the line is kept.
      stripped="${line//<${term}>/}"
      if grep -qE -- "$pattern" <<<"$stripped"; then
        matches="${matches}${line}"$'\n'
      fi
    done <<< "$raw_matches"

    if [[ -n "$matches" ]]; then
      source_file="${term_to_source[$term]}"
      echo "  DANGLING: '${term}' referenced in ${candidate_rel}"
      echo "            (file being deleted: ${source_file})"
      while IFS= read -r match_line; do
        [[ -z "$match_line" ]] && continue
        echo "    ${match_line}"
      done <<< "$matches"
      echo ""
      FAILED=1
    fi
  done
done

if [[ "$FAILED" -ne 0 ]]; then
  echo "Pre-commit check failed: dangling references to deleted files found." >&2
  echo "Update or remove the references listed above before committing." >&2
  echo "To bypass (exceptional cases only): git commit --no-verify" >&2
  exit 1
fi

echo "No dangling references found."
exit 0

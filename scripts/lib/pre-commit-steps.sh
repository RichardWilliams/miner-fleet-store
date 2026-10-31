# shellcheck shell=bash
# pre-commit-steps.sh — the one list of the files .githooks/pre-commit needs
# besides itself (cs#1969).
#
# The hook calls a script per step, and one step script sources libraries.
# A repo that carries the hook without those files used to skip the step
# silently. The list is declared HERE, once, and read by every consumer:
#   - .githooks/pre-commit sources this file, refuses the commit when any
#     listed file is missing (or a step script is not executable), and calls
#     each step script through the names below;
#   - in the codespace, which carries the canonical copy of this list and of
#     every file on it, scripts/lib/canonical-copies.sh copies and compares
#     exactly these files, for the sync (scripts/propagate-canonical-copies.sh,
#     setup-repo.sh) and for the completeness check
#     (scripts/check-propagation-completeness.sh).
# A step that calls a new script, or a step script that sources a new
# library, adds it here, in the codespace; its tests/canonical-copies.test.sh
# commits through the hook in a repo holding only these files, so a file
# missing from the list fails that test (cs#2015).
#
# No shebang — this file is sourced only. Paths are repo-relative.
#
# Public functions:
#   pre_commit_step_scripts   print each step script, one per line
#   pre_commit_payload        print every file the hook needs besides itself:
#                             this list, the step scripts, and the libraries
#                             they source
#   pre_commit_missing <repo-root>
#                             print each payload file absent from <repo-root>,
#                             and each step script there that is not
#                             executable; print nothing when all are in place

PRE_COMMIT_DANGLING_REFS="scripts/check-dangling-refs.sh"
PRE_COMMIT_AGENT_LINT="scripts/check-agent-lint.sh"
PRE_COMMIT_SYNC_SETTINGS="scripts/sync-settings.sh"
PRE_COMMIT_ENV_FILES="scripts/check-staged-env-files.sh"

pre_commit_step_scripts() {
  printf '%s\n' \
    "$PRE_COMMIT_DANGLING_REFS" \
    "$PRE_COMMIT_AGENT_LINT" \
    "$PRE_COMMIT_SYNC_SETTINGS" \
    "$PRE_COMMIT_ENV_FILES"
}

# The libraries the step scripts source: sync-settings.sh sources
# atomic-write.sh, which sources resolve-path.sh.
_pre_commit_step_libs() {
  printf '%s\n' \
    "scripts/lib/atomic-write.sh" \
    "scripts/lib/resolve-path.sh"
}

pre_commit_payload() {
  printf '%s\n' "scripts/lib/pre-commit-steps.sh"
  pre_commit_step_scripts
  _pre_commit_step_libs
}

pre_commit_missing() {
  local repo_root="$1" rel
  while IFS= read -r rel; do
    [[ -f "${repo_root}/${rel}" ]] || printf '%s\n' "$rel"
  done < <(pre_commit_payload)
  while IFS= read -r rel; do
    if [[ -f "${repo_root}/${rel}" && ! -x "${repo_root}/${rel}" ]]; then
      printf '%s (not executable)\n' "$rel"
    fi
  done < <(pre_commit_step_scripts)
}

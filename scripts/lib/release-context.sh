#!/usr/bin/env bash
#
# The release procedure's own knowledge: the fail-closed gates a release bump is
# verified by, and the one rendering of that list the driver's hand-off prints.
#
# A SIBLING of scripts/lib/repo-context.sh, not a part of it. That file holds
# this repo's COORDINATES — its GitHub slugs, its registry coordinate, the paths
# of the files a release rewrites, and the patterns derived from them — at the
# fixed conventional path INVARIANTS.md § Encapsulation mandates for the
# `owner/repo` slug, and its name is scope-neutral for exactly that reason. The
# same invariant provides for this file in the same breath: a
# "`release-context.sh` (or similarly domain-scoped) sibling library MAY still
# exist alongside it to hold that repo's own release-specific logic, sourcing
# the coordinate from here rather than declaring it itself".
#
# Which gate scripts a release is verified by is neither a coordinate nor a
# derivation from one — it is procedural knowledge about how this repo verifies
# a release, and it is declared here for that reason.
# RichardWilliams/miner-fleet carries a scripts/lib/release-context.sh of its
# own, so this is the estate's established shape rather than a new one.
#
# It declares no coordinate, and it READS none either, so it sources nothing. A
# `source` of repo-context.sh here would bind a dependency no line below uses:
# every value in this file is a gate-script basename. A consumer needing both
# sources both — scripts/release.sh does, and so does DEPLOY.md § 3.1's hand
# path.
#
# SOURCE this file, never execute it — mode 644, the same convention as
# scripts/lib/repo-context.sh and scripts/lib/check-common.sh.
#
# Assignments are plain rather than `readonly`, for the same reason they are in
# repo-context.sh: a consumer that sources this file more than once in a single
# shell does not abort on a re-assignment to a read-only name.

# --- The gates a release is verified by --------------------------------------

# The fail-closed gates a release bump is verified by, named ONCE. The release
# driver guards their existence before it fetches anything and re-runs every one
# of them against the tree it just wrote; the hand-off it prints names them in
# its PR body; DEPLOY.md § 3.1's hand path sources this file and loops over the
# same array; and tests/test-release.sh copies exactly these gates into every
# fixture it builds.
#
# The list lived in scripts/release.sh until a second, hand-written copy of it
# in that script's own PR body drifted: the body named three gates while the
# array ran four, having missed check-secret-leak.sh when that gate was added.
# A driver can be sourced by nothing, so a doc or a suite that wanted the list
# had no choice but to spell it out again. Declaring it in a sourceable library
# is what lets every consumer READ it instead (INVARIANTS.md § Encapsulation).
#
# Two sites still name these gates and can read neither this array nor anything
# derived from it, so each is held true by its own mechanism rather than by care:
#
#   - `.local-ci.yml` runs each gate as its own named step with its own timeout
#     and its own rationale, and runs six test suites besides. It is the
#     operator-authored CI step set (INVARIANTS.md § Local CI Equivalence) rather
#     than a copy of this list, and YAML can source nothing. tests/test-release.sh
#     asserts that every entry here has a step there, so a gate added to this
#     array and forgotten there goes red instead of running at bump time and
#     never at push time.
#   - DEPLOY.md § 3.1 step 5's prose names two of them individually, to say why
#     the SET has to be run together rather than to enumerate the set. Adding a
#     gate here does not date it.
RELEASE_GATES=(
  check-version-drift
  check-release-notes-drift
  check-deploy-contract
  check-secret-leak
)

# --- The one rendering of that list ------------------------------------------

# render_gate_list — the declared gates as one backticked English list.
#
# The driver's hand-off PR body has to name the gates the run verified with, and
# a sentence typed beside RELEASE_GATES is a second copy of it in prose. The
# copy this replaced had already drifted, in the same way and for the same
# reason the array's own history above records. Building the sentence from the
# array removes the second copy — change the array and the sentence moves with
# it (INVARIANTS.md § Encapsulation).
#
# It sits beside the array rather than in the driver because it renders that
# array and nothing else, and because a function declared in the driver can be
# read by no other consumer — the same property that kept the array itself out
# of every consumer's reach until it was declared somewhere sourceable.
render_gate_list() {
  local rendered="" index=0
  local last=$(( ${#RELEASE_GATES[@]} - 1 ))
  for (( index = 0; index <= last; index++ )); do
    if (( index == last && index > 0 )); then
      rendered+=" and "
    elif (( index > 0 )); then
      rendered+=", "
    fi
    rendered+="\`${RELEASE_GATES[index]}.sh\`"
  done
  printf '%s' "$rendered"
}

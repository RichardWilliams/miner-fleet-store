#!/usr/bin/env bash
#
# The release procedure's own knowledge: the fail-closed gates a release bump is
# verified by, and the one rendering of that list the driver's hand-off prints.
#
# A SIBLING of scripts/lib/repo-context.sh, not a part of it. THAT FILE'S HEADER
# OWNS the coordinate-versus-procedure split, the INVARIANTS.md § Encapsulation
# text behind it, and the clause providing for this file — read it there rather
# than here. Restating it in both places would be two copies of one rationale,
# free to drift, in a pair of files whose whole subject is not doing that.
#
# What is true of THIS file and nowhere else: it declares no coordinate and
# READS none, so it sources nothing. Every value below is a gate-script
# basename, and a `source` of repo-context.sh would bind a dependency no line
# uses. A consumer needing both sources both — scripts/release.sh does, and so
# does DEPLOY.md § 3.1's hand path.
#
# Its file conventions are repo-context.sh's, for the reasons stated there:
# source it and never execute it (mode 644), and its assignments are plain
# rather than `readonly`.

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

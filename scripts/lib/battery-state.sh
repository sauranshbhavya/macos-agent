#!/usr/bin/env bash
# The one place anything in this repository asks "is a mutation battery holding this checkout, and
# did a killed one leave a mutant behind?".
#
# Two separate hazards live behind that question, and they are opposites:
#
#   live      — `scripts/mutate` is running right now, so the tree is mid-mutant BY CONSTRUCTION.
#               Anything that compiles what is on disk gets a genuine failure about a state nobody
#               asked about, and its output reads exactly like a regression (SONNY-258, PR #109).
#   abandoned — a battery was killed with the mutant applied, so the tree carries a deliberate
#               defect nobody wrote down, and the suite may well be green: a surviving mutant is by
#               definition one no test catches (SONNY-347).
#
# Sourced by `scripts/mutate` itself, by the other tools in scripts/ that compile the tree, and by
# .claude/hooks/. It exits nothing and traps nothing — every function returns, so a caller running
# under `set -e` keeps its own control flow.
#
# The reading is deliberately identical to the one `scripts/mutate` applies to its own lock: a pid
# that no longer exists is the ordinary killed-run case, and a pid that exists but belongs to
# something else is pid reuse, which on a Mac that has wrapped its pid space is not exotic.

# Set by battery_state(). BATTERY_STATE is the only one always meaningful.
BATTERY_STATE="unknown"   # none | live | abandoned | unknown (not a git checkout)
BATTERY_LOCK=""
BATTERY_PID=""
BATTERY_STARTED=""
BATTERY_PLAN=""
BATTERY_HEAD=""
BATTERY_FILE=""           # abandoned only: the mutated file, repository-root-relative
BATTERY_ID=""             # abandoned only: the mutant's id from the plan
BATTERY_MUTANT_SHA=""     # abandoned only: the HEAD the killed run was measuring

battery_lock_dir() {
  local git_dir
  git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [ -n "$git_dir" ] || return 1
  printf '%s/mutate.lock' "$git_dir"
}

battery_record_field() {
  # battery_record_field <file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2 //p" "$1" | head -1
}

# Is this pid a live battery? Both halves matter: the pid must exist AND its command line must name
# the tool, or a reused pid reads as a battery that ended long ago.
battery_owner_alive() {
  local pid="$1" command
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [ -n "$command" ] || return 1
  case "$command" in
    *mutate*) return 0 ;;
  esac
  return 1
}

# The whole reading, in one call. Never fails: a directory that is not a git checkout answers
# "unknown", which every caller treats as "not my business" rather than as an error.
battery_state() {
  BATTERY_STATE="unknown"
  BATTERY_LOCK=""; BATTERY_PID=""; BATTERY_STARTED=""; BATTERY_PLAN=""; BATTERY_HEAD=""
  BATTERY_FILE=""; BATTERY_ID=""; BATTERY_MUTANT_SHA=""

  local lock
  lock="$(battery_lock_dir)" || return 0
  BATTERY_LOCK="$lock"
  BATTERY_STATE="none"

  [ -d "$lock" ] || return 0

  BATTERY_PID="$(battery_record_field "$lock/owner" pid)"
  BATTERY_STARTED="$(battery_record_field "$lock/owner" started)"
  BATTERY_PLAN="$(battery_record_field "$lock/owner" plan)"
  BATTERY_HEAD="$(battery_record_field "$lock/owner" head)"

  if battery_owner_alive "$BATTERY_PID"; then
    BATTERY_STATE="live"
    return 0
  fi

  # The owner is gone. A lock alone is the harmless leftover `scripts/mutate unlock` has always
  # cleared. An in-flight record beside it means the run was killed with a mutant applied.
  if [ -f "$lock/inflight/meta" ]; then
    BATTERY_ID="$(battery_record_field "$lock/inflight/meta" id)"
    BATTERY_FILE="$(battery_record_field "$lock/inflight/meta" file)"
    BATTERY_MUTANT_SHA="$(battery_record_field "$lock/inflight/meta" sha)"
    BATTERY_STATE="abandoned"
  fi
  return 0
}

# The shared wording. Every consumer prints its own first line — what IT decided to do — and then
# this, so the explanation of the state cannot drift between the tools that read it.
battery_state_detail() {
  case "$BATTERY_STATE" in
    live)
      printf '  battery pid : %s\n' "${BATTERY_PID:-unknown}"
      printf '  started     : %s\n' "${BATTERY_STARTED:-unknown}"
      printf '  plan        : %s\n' "${BATTERY_PLAN:-unknown}"
      printf '  head        : %s\n' "${BATTERY_HEAD:-unknown}"
      printf '  lock        : %s\n' "$BATTERY_LOCK"
      printf '\n'
      printf 'A battery is mid-mutant by construction: it edits a source file, runs the suite, and\n'
      printf 'restores the file. Anything that compiles this tree while that is happening measures a\n'
      printf 'deliberately broken file, and reports a genuine failure that reads exactly like a\n'
      printf 'regression. Wait for pid %s to finish, then re-run.\n' "${BATTERY_PID:-unknown}"
      ;;
    abandoned)
      printf '  mutant      : %s\n' "${BATTERY_ID:-unknown}"
      printf '  file        : %s\n' "${BATTERY_FILE:-unknown}"
      printf '  measured at : %s\n' "${BATTERY_MUTANT_SHA:-unknown}"
      printf '  killed run  : pid %s, started %s\n' "${BATTERY_PID:-unknown}" "${BATTERY_STARTED:-unknown}"
      printf '\n'
      printf 'That battery was killed with the mutant still applied, so the file above carries a\n'
      printf 'deliberate defect right now. The suite may well be green over it — a mutant that\n'
      printf 'survives is by definition one no test catches — so nothing else here will notice, and\n'
      printf 'a commit or a rebase from this tree carries the defect with it.\n'
      printf '\n'
      printf 'Recover it:  scripts/mutate unlock\n'
      printf 'That restores %s from the copy the killed run took before it\n' "${BATTERY_FILE:-the file}"
      printf 'mutated anything, and then clears the lock.\n'
      ;;
  esac
}

# Where a tool records that it skipped, or refused, because of the state above. In the per-worktree
# git directory, never in the working tree: a battery aborts its own run the moment anything writes
# a tracked file underneath it (`require_clean_tree_after`), so a journal in the tree would turn a
# guard against a false red into a cause of one.
battery_journal_path() {
  local git_dir
  git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [ -n "$git_dir" ] || return 1
  printf '%s/battery-skips.log' "$git_dir"
}

# battery_journal <tool> <what it did and why>
#
# The durable half of "a skip must say it skipped". A message on a terminal is read once by whoever
# is looking; this is what is still there when someone asks later why a check that should have run
# produced nothing. Silent failure here is deliberate — a tool must not die because it could not
# write a note about not dying.
battery_journal() {
  local path
  path="$(battery_journal_path)" || return 0
  {
    printf '%s\t%s\t%s\t%s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$BATTERY_STATE" "$2"
  } >>"$path" 2>/dev/null || true
}

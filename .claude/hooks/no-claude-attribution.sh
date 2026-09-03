#!/usr/bin/env bash
# PreToolUse hook on Bash. Refuses to let a Claude attribution reach a commit message, a PR body
# or a ticket, and installs the git-level hook that catches what a command line cannot show
# (SONNY-406).
#
# WHY THIS EXISTS. `CLAUDE.md` has forbidden this in plain terms since 527d5390, and on 2026-09-03
# eight commits carrying a co-author trailer and a claude.ai session URL reached `main` in one PR,
# written by a lane that had followed dozens of rules from that same file with unusual care. The
# finding was not that the rule is unfindable — three of four lanes in that wave got it right. It
# is that the harness supplies the opposite instruction at the exact moment of the commit, prose
# was the only thing arguing back, and prose lost. So this is the argument that does not depend on
# a session remembering anything.
#
# THE TWO LAYERS, and why neither is the other's spare:
#
#   .githooks/commit-msg     reads the message git is about to commit. Every route reaches it —
#                            -m, -F, a heredoc, the editor, --amend. It is the real barrier for
#                            commits, and it cannot see a PR body or a ticket at all.
#   this file                reads a command line before it runs. That is strictly less than the
#                            final commit message, so it is NOT the commit barrier. It is here for
#                            the two surfaces git has no opinion about (a PR body, ticket content),
#                            for `--no-verify`, which switches the other layer off, and to make
#                            sure the other layer is installed in the first place.
#
# CONTRACT: stdin is the PreToolUse payload; exit 0 allows, exit 2 blocks and returns stderr to the
# session. Anything unexpected exits 0 — a hook on every Bash call that fails closed on its own
# bugs takes the session down with it. The one thing it will not fail open on is a watched command
# it could not actually check; that is a refusal, because "not checked" must never read as "clean".
set -u

payload="$(cat)"

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
[ "$tool" = "Bash" ] || exit 0

command_text="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$command_text" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$root" ] || root="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$root" ] && [ -d "$root" ] || exit 0

# ---------------------------------------------------------------------------------------------
# Is this a command that can carry an attribution to one of the three surfaces?
#
# Decided on the command text with HEREDOC BODIES REMOVED, and this is not a refinement — the
# first live action of this hook was to refuse the command that was writing its own selftest,
# because that command is a `cat` whose heredoc body quotes every forbidden shape and the words
# "git" and "commit" besides. A heredoc body is data being written, not a command being run, and a
# guard that cannot tell those apart refuses `cat`, `printf`, and every document that discusses the
# rule. That failure mode is how a guard gets switched off in its first week.
#
# The SCAN below still reads the full text, heredocs included, because a `gh pr create --body` can
# genuinely carry its body in a heredoc and nothing downstream would catch that one. So: a heredoc
# decides nothing about WHETHER to look, and everything about WHAT is looked at.
#
# The cheap `case` on the raw text comes first, so the common command — which mentions none of
# these words anywhere — costs no extra process at all.
# ---------------------------------------------------------------------------------------------
case "$command_text" in
  *commit*|*"gh pr"*|*"gh issue"*|*"gh release"*|*plane*) : ;;
  *) exit 0 ;;
esac

# Strip heredoc bodies: from the line after a `<<WORD` redirection (`<<-`, quoted or bare) up to
# the line that is exactly WORD, indentation tolerated because `<<-` strips tabs.
command_words="$(printf '%s\n' "$command_text" | awk '
  $0 ~ /<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/ && term == "" {
    line = $0
    if (match(line, /<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
      t = substr(line, RSTART, RLENGTH)
      gsub(/^<<-?[[:space:]]*/, "", t); gsub(/["'"'"']/, "", t)
      term = t
      print line
      next
    }
  }
  term != "" {
    stripped = $0
    gsub(/^[[:space:]]+/, "", stripped)
    if (stripped == term) { term = "" }
    next
  }
  { print }
')"

is_commit=0
is_watched=0
case "$command_words" in
  *"git commit"*|*"git "*" commit"*) is_commit=1; is_watched=1 ;;
esac
case "$command_words" in
  *"gh pr create"*|*"gh pr edit"*|*"gh pr comment"*|*"gh issue create"*|*"gh issue comment"*|*"gh release create"*)
    is_watched=1 ;;
  *"plane create"*|*"plane comment"*|*"plane update"*)
    is_watched=1 ;;
esac
[ "$is_watched" -eq 1 ] || exit 0

lib="$root/scripts/lib/no-attribution.sh"
if [ ! -r "$lib" ]; then
  {
    printf 'REFUSED: scripts/lib/no-attribution.sh is missing from this checkout, so nothing\n'
    printf 'checked this command for a Claude attribution.\n\n'
    printf 'Looked for: %s\n' "$lib"
    printf 'This is a broken checkout, not a clean command. Restore the file and retry.\n'
  } >&2
  exit 2
fi
# shellcheck source=../../scripts/lib/no-attribution.sh
. "$lib"

refuse() {
  # $1 what was found (already formatted), $2 where
  {
    printf 'REFUSED: this command would put a Claude attribution into %s.\n\n' "$2"
    printf '%s\n' "$1" | sed 's/^/    /'
    printf '\n'
    no_attribution_explain
  } >&2
  exit 2
}

# ---------------------------------------------------------------------------------------------
# 1. The command text itself. Covers -m "...", a heredoc body, and gh --body "...".
# ---------------------------------------------------------------------------------------------
hits="$(printf '%s\n' "$command_text" | no_attribution_scan_stdin)"
if [ -n "$hits" ]; then
  refuse "$hits" "a commit message, PR body or ticket"
fi

# ---------------------------------------------------------------------------------------------
# 2. Any file the command names.
#
# Every route that hides the text from the command line puts it in a file instead — `git commit -F`,
# `gh pr create --body-file`, `scripts/plane comment SONNY-12 <html>`. Rather than parsing each
# tool's flags, every token that resolves to a readable regular file gets scanned. A wrong guess
# costs one grep of a file that was going to be read anyway; a missed flag costs the whole point.
# ---------------------------------------------------------------------------------------------
scan_named_files() {
  local tok path
  # shellcheck disable=SC2086
  for tok in $command_words; do
    # strip one layer of surrounding quotes and any trailing shell punctuation
    tok="${tok%\"}"; tok="${tok#\"}"
    tok="${tok%\'}"; tok="${tok#\'}"
    tok="${tok%;}"; tok="${tok%)}"
    case "$tok" in
      -*|"") continue ;;
    esac
    path="$tok"
    case "$path" in
      /*) : ;;
      *)  path="$root/$tok" ;;
    esac
    [ -f "$path" ] && [ -r "$path" ] || continue
    # A commit message, a PR body and a ticket are all small. Anything large is not one of them,
    # and scanning a build artefact a command happens to name is wasted work.
    local size
    size="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
    [ -n "$size" ] && [ "$size" -le 262144 ] || continue
    local fhits
    fhits="$(no_attribution_scan_file "$path" 2>/dev/null)"
    if [ -n "$fhits" ]; then
      refuse "$(printf '%s\n' "$fhits" | sed "s|^|$tok:|")" "the file $tok"
    fi
  done
}
scan_named_files

# ---------------------------------------------------------------------------------------------
# 3. Commit-only: the flag that switches the other layer off, and the config that switches it on.
# ---------------------------------------------------------------------------------------------
[ "$is_commit" -eq 1 ] || exit 0

# Confined to the `git commit ...` segment rather than matched over the whole command, so that a
# `git commit -m x && echo -n done` is not refused for the `-n` belonging to echo. `-n` is git's
# own short spelling of --no-verify, so both are refused.
if printf '%s' "$command_words" \
     | grep -qE 'git([[:space:]]+-[^[:space:]]+|[[:space:]]+[^-][^[:space:]]*)*[[:space:]]+commit[^&|;]*([[:space:]]--no-verify|[[:space:]]-n)([[:space:]]|$)'; then
    {
      printf 'REFUSED: --no-verify on a commit.\n\n'
      printf 'That flag skips .githooks/commit-msg, which is the only barrier that reads the\n'
      printf 'message git is actually about to commit. Skipping it is how an attribution reaches\n'
      printf '`main` even with this hook installed, so it is refused rather than warned about.\n\n'
      printf 'If a hook is genuinely wrong about your commit, that is a finding to report — not a\n'
      printf 'flag to add.\n'
    } >&2
    exit 2
fi

# Install the git hook if nothing has. This is the answer to "a committed hook only survives a
# fresh worktree if something sets core.hooksPath" — this is what sets it, at the first commit of
# any session, so no clone needs a remembered setup step. A relative path resolves per worktree, so
# one config covers every lane.
current="$(git -C "$root" config --get core.hooksPath 2>/dev/null || true)"
if [ -z "$current" ]; then
  if git -C "$root" config core.hooksPath .githooks 2>/dev/null; then
    printf 'no-attribution: set core.hooksPath=.githooks in this clone so .githooks/commit-msg runs.\n' >&2
  else
    {
      printf 'REFUSED: could not set core.hooksPath, so .githooks/commit-msg is NOT running and\n'
      printf 'nothing will read the message this commit is about to make.\n\n'
      printf 'Run this once, then retry:  git -C %s config core.hooksPath .githooks\n' "$root"
    } >&2
    exit 2
  fi
elif [ "$current" != ".githooks" ]; then
  # Do not overwrite it. Another hooks directory may carry hooks this repository knows nothing
  # about, and silently repointing git at ours would delete them from the session's view.
  {
    printf 'REFUSED: core.hooksPath is set to %s, not .githooks, so .githooks/commit-msg is not\n' "$current"
    printf 'running and no barrier is reading this commit message.\n\n'
    printf 'This is not overwritten automatically, because that directory may hold hooks this\n'
    printf 'repository does not know about. Either point git at .githooks, or copy\n'
    printf '.githooks/commit-msg into %s.\n' "$current"
  } >&2
  exit 2
fi

exit 0

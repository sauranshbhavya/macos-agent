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

# ---------------------------------------------------------------------------------------------
# Reading the payload, and what happens when that cannot be done (PR #195 review, F5).
#
# The first version read all three fields through `jq` and treated an empty answer as "not my
# business". So with `jq` missing or broken, EVERY field came back empty, the hook exited 0, and
# the whole layer vanished — measured: a `gh pr create` carrying a footer was allowed, exit 0, with
# nothing on stderr. That is this file's own contract inverted; the header promises that a watched
# command it could not check is a refusal, and the branch that promise lives in was unreachable in
# exactly the case it was written for. It is also the clean-zero family from CLAUDE.md, inside a
# guard whose entire design is organised against it.
#
# So: `jq`, then `python3`, and if neither can parse it, the raw payload is scanned as text. A
# match refuses — the class is there whatever the shape around it — and a clean raw scan allows the
# call but says on stderr that nothing was parsed, because taking every Bash call down over a
# broken `jq` is worse than the hole it closes. What must never happen is silence, and that is the
# part with a selftest arm.
# ---------------------------------------------------------------------------------------------
parsed=0
if tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" && [ -n "$tool" ]; then
  parsed=1
  command_text="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  payload_cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
elif command -v python3 >/dev/null 2>&1; then
  # BASE64, and the reason is a defect this fallback shipped with (PR #195 cycle-3, G1). It printed
  # the three fields on three lines and read them back with `sed -n 1p/2p/3p` — and the command
  # field CONTAINS NEWLINES, which is the ordinary case for a PR body. So `2p` took the command's
  # first line only and `3p` took its second line as the cwd: with jq broken, a footer on line 2 of
  # a body was allowed, exit 0, and silently, because `parsed=1` had been set and the "NOT checked"
  # notice therefore never fired. The one property this whole fallback exists to establish was the
  # one that case lost. Base64 has no newline inside a field, so a line selector is safe again.
  if fields="$(printf '%s' "$payload" | python3 -c '
import base64, json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
def enc(v):
    return base64.b64encode((v or "").encode("utf-8")).decode("ascii")
print(enc(d.get("tool_name")))
print(enc((d.get("tool_input") or {}).get("command")))
print(enc(d.get("cwd")))
' 2>/dev/null)"; then
    tool="$(printf '%s' "$fields" | sed -n '1p' | base64 -d 2>/dev/null)"
    command_text="$(printf '%s' "$fields" | sed -n '2p' | base64 -d 2>/dev/null)"
    payload_cwd="$(printf '%s' "$fields" | sed -n '3p' | base64 -d 2>/dev/null)"
    # `parsed=1` AFTER the decodes and only on a non-empty result, which is the whole of the fix
    # for PR #195's scoped round, H1. `base64` is a THIRD tool this path needs, and setting the
    # flag before the decodes put it on the far side of the safety net: with `jq` and `base64` both
    # unusable, `tool` came out empty, the `Bash` check below exited 0, and the raw-payload scan
    # never ran because `parsed` was already 1 — allowed, exit 0, nothing on stderr. Isolated one
    # tool at a time, `base64` alone and `jq` alone and `jq`+`python3` were each refused; only that
    # one pair was silent. This matches the `jq` branch above, which has always required a non-empty
    # `tool` before claiming the payload was parsed.
    [ -n "$tool" ] && parsed=1
  fi
fi

if [ "$parsed" -eq 0 ]; then
  raw_root="${CLAUDE_PROJECT_DIR:-}"
  raw_lib="$raw_root/scripts/lib/no-attribution.sh"
  if [ -n "$raw_root" ] && [ -r "$raw_lib" ]; then
    # shellcheck source=../../scripts/lib/no-attribution.sh
    . "$raw_lib"
    if printf '%s' "$payload" | grep -qEi -- "$(no_attribution_pattern)"; then
      {
        printf 'REFUSED: this hook could not parse its own payload, and the raw payload carries a
'
        printf 'Claude attribution.

'
        no_attribution_explain
        printf '
Neither jq nor python3 could read the payload, so which command this is could not
'
        printf 'be determined. It is refused rather than allowed, because "not checked" must never
'
        printf 'read as "clean".
'
      } >&2
      exit 2
    fi
  fi
  printf 'no-attribution: could not parse the PreToolUse payload (jq and python3 both failed).
' >&2
  printf 'This command was NOT checked for a Claude attribution. Nothing here says it is clean.
' >&2
  exit 0
fi

[ "$tool" = "Bash" ] || exit 0
[ -n "$command_text" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$root" ] || root="$payload_cwd"
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
# The cheap `case` comes first so that the common command — one mentioning none of these words
# anywhere — never reaches the heredoc stripping or the file scan below. It is NOT free: two `tr`
# processes run before it, on every Bash tool call in this repository, because the gate has to
# tolerate repeated whitespace. This sentence used to claim the pre-filter "costs no extra process
# at all", which was true when it was written and was made false by the fix two paragraphs down
# (PR #195 cycle-3, G7). That cost has not been measured; a residual on SONNY-406 owes it.
# ---------------------------------------------------------------------------------------------
# Whitespace collapses HERE and not only at the real gate below. The first fix normalised the gate
# and left this cheap pre-filter matching the literal `gh pr`, so `gh  pr create` with two spaces
# still exited 0 one step earlier than the thing that had just been fixed — the same defect, moved.
# Found by re-running the review's own probe against the fix rather than by reading it.
command_squeezed="$(printf '%s' "$command_text" | tr '\n\t' '  ' | tr -s ' ')"
case "$command_squeezed" in
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

# Runs of whitespace collapse before the gate is matched: the gate is a literal substring test, so
# `gh  pr create` with two spaces walked straight past it (PR #195 review, F3).
command_gate="$(printf '%s' "$command_words" | tr '\n\t' '  ' | tr -s ' ')"

is_commit=0
is_watched=0
case "$command_gate" in
  *"git commit"*|*"git "*" commit"*) is_commit=1; is_watched=1 ;;
esac
case "$command_gate" in
  *"gh pr create"*|*"gh pr edit"*|*"gh pr comment"*|*"gh pr review"*|*"gh issue create"*|*"gh issue comment"*|*"gh release create"*)
    is_watched=1 ;;
  *"plane create"*|*"plane comment"*|*"plane update"*)
    is_watched=1 ;;
esac
# KNOWN LIMITATION, and it is a decision rather than an oversight (founder, 2026-09-03, recorded on
# SONNY-410). `gh api` is NOT watched, in any form. It posts arbitrary JSON to any endpoint, so
# covering it means recognising every payload shape GitHub accepts, with no way to prove the set is
# complete — and a guard that claims a surface it cannot prove claims more than it holds, which is
# the failure this whole ticket exists to stop. `gh api repos/o/r/issues/1/comments -f body=…` is a
# measured route past this layer. `scripts/no-attribution prs` is the honest cover: it reads every
# PR body after the fact, whatever wrote it.
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
# The directories a relative token may be resolved against: the repository root, plus any `cd`
# target in the command. `cd server && gh pr create --body-file body.md` names a file that exists
# only under `server/`, and resolving against the root alone made it invisible (PR #195 review, F3).
scan_bases() {
  local d
  printf '%s\n' "$root"
  printf '%s' "$command_words" \
    | grep -oE '(^|[;&|][[:space:]]*)cd[[:space:]]+[^;&|[:space:]]+' 2>/dev/null \
    | sed -E 's/.*cd[[:space:]]+//' \
    | while IFS= read -r d; do
        [ -n "$d" ] || continue
        case "$d" in
          /*) printf '%s\n' "$d" ;;
          *)  printf '%s\n' "$root/$d" ;;
        esac
      done
}

# scan_candidate <absolute path> <token as written>. Refuses and exits if the file carries the
# class; returns quietly otherwise.
scan_candidate() {
  local path="$1" tok="$2" rel size fhits
  [ -f "$path" ] && [ -r "$path" ] || return 0
  # The files that DEFINE the class match it by construction. Scanning one refuses a command that
  # merely sources or reads it, which is what happened on the first command run after this guard
  # was committed. Exempt from being read AS A NAMED FILE and from nothing else — a commit whose
  # message came from one is still read by .githooks/commit-msg.
  #
  # ONE check, on the path this RESOLVED to. There were two (PR #195 cycle-3, G6): a second on the
  # token as written, which was a widening rather than a duplicate — it exempted by spelling rather
  # than by file — and either could be deleted with all 60 cases green, so neither was pinned. That
  # is the round's own "a component is pinned only by a fixture carrying that component and nothing
  # else" rule, applied to the round's own fix.
  rel="${path#"$root/"}"
  no_attribution_is_self_referential "$rel" && return 0
  # A commit message, a PR body and a ticket are all small. Anything large is not one of them.
  size="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
  [ -n "$size" ] && [ "$size" -le 262144 ] || return 0
  fhits="$(no_attribution_scan_file "$path" 2>/dev/null)"
  if [ -n "$fhits" ]; then
    refuse "$(printf '%s\n' "$fhits" | sed "s|^|$tok:|")" "the file $tok"
  fi
  return 0
}

scan_named_files() {
  local tok base
  # shellcheck disable=SC2086
  for tok in $command_words; do
    # strip one layer of surrounding quotes and any trailing shell punctuation
    tok="${tok%\"}"; tok="${tok#\"}"
    tok="${tok%\'}"; tok="${tok#\'}"
    tok="${tok%;}"; tok="${tok%)}"
    # `--body-file=x` is one token, and skipping every token starting with `-` skipped the
    # filename with it — a measured route past this layer (PR #195 review, F3). The value after
    # the first `=` is the candidate path.
    # `--body-file=x` and `-Fx` are both one token, and skipping everything starting with `-`
    # skipped the filename with it. The long form was closed in the fix round and the attached
    # short form was the same route one spelling over (PR #195 cycle-3, G4); `-F` is the only
    # file-valued short flag that matters here, and both `gh` and `git commit` spell it that way.
    case "$tok" in
      --*=*) tok="${tok#*=}" ;;
      -F?*)  tok="${tok#-F}" ;;
    esac
    case "$tok" in
      -*|"") continue ;;
    esac
    # EVERY base, not the first that resolves (PR #195 cycle-3, G2). Breaking at the first, with
    # the repository root first in the list, meant that when the same relative name existed at both
    # the hook opened the ROOT's copy while the command — running in the `cd` target — would read
    # the other one. Measured: clean at the root, a footer under `server/`, allowed and silent.
    # Ordering the `cd` targets first would fix that case and pick a different wrong file the next
    # time; scanning all of them cannot.
    case "$tok" in
      /*) scan_candidate "$tok" "$tok" ;;
      *)  while IFS= read -r base; do
            [ -n "$base" ] || continue
            scan_candidate "$base/$tok" "$tok"
          done <<EOF
$(scan_bases)
EOF
          ;;
    esac
  done
}
scan_named_files

# ---------------------------------------------------------------------------------------------
# 3. Commit-only: the flag that switches the other layer off, and the config that switches it on.
# ---------------------------------------------------------------------------------------------
[ "$is_commit" -eq 1 ] || exit 0

# ---------------------------------------------------------------------------------------------
# Three routes past this refusal were measured in PR #195's review (F4), and all three are closed
# here. Each was silent — exit 0, no output.
#
#   1. QUOTED STRINGS ARE REMOVED FIRST. The scan confines itself with `[^&|;]*` so that an `-n`
#      belonging to a later `echo` is not refused — right intent, and it meant a SUBJECT LINE
#      containing a semicolon or an ampersand ended the scan before the flag. `git commit -m
#      "fix: a; b" --no-verify` was allowed. Deleting quoted spans first means punctuation inside
#      a message cannot terminate anything, and the operator guard still does its real job.
#   2. BUNDLED SHORT FLAGS. `git commit -nm "docs: clean"` was allowed, and it works — measured in
#      a scratch repository against a hook that always fails: the hook was skipped and the commit
#      made. The old pattern wanted `-n` followed by whitespace. Any single-dash cluster
#      containing an `n` is git's `--no-verify`, so that is what is matched.
#   3. `-c core.hooksPath=…`. `git -c core.hooksPath=/dev/null commit -m …` skips the hook and
#      makes the commit, and the install arm below cannot see it, because `-c` is per-command and
#      `git config --get` still reports `.githooks`. The INSTALL arm cannot see it; this refusal
#      can, because the override is written on the command line where it is plainly readable.
# ---------------------------------------------------------------------------------------------
command_flags="$(printf '%s' "$command_words" | sed -e "s/'[^']*'/ /g" -e 's/"[^"]*"/ /g')"

no_verify_reason=""
if printf '%s' "$command_flags" \
     | grep -qE 'git([[:space:]]+-[^[:space:]]+|[[:space:]]+[^-][^[:space:]]*)*[[:space:]]+commit[^&|;]*([[:space:]]--no-verify([[:space:]]|$)|[[:space:]]-[A-Za-z]*n[A-Za-z]*([[:space:]]|$))'; then
  no_verify_reason="--no-verify (or its short spelling, bundled or not)"
elif printf '%s' "$command_flags" | grep -qE '[[:space:]]-c[[:space:]]+core\.hooksPath='; then
  no_verify_reason="-c core.hooksPath=, which is --no-verify under another name"
fi

if [ -n "$no_verify_reason" ]; then
    {
      printf 'REFUSED: %s on a commit.\n\n' "$no_verify_reason"
      printf 'That skips .githooks/commit-msg, which is the only barrier that reads the message\n'
      printf 'git is actually about to commit. Skipping it is how an attribution reaches `main`\n'
      printf 'even with this hook installed, so it is refused rather than warned about.\n\n'
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

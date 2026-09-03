#!/usr/bin/env bash
# Re-prove every arm of the no-attribution guard still refuses what it names.
#
#     .claude/hooks/no-claude-attribution-selftest.sh
#
# Exit 0 when every arm holds, 2 when one does not. About two seconds; it builds throwaway git
# repositories under a temporary directory and never touches this one — in particular it never
# reads or writes this clone's core.hooksPath, which three of the arms below set inside a fixture.
#
# WHY THIS EXISTS (SONNY-406). The guard it drives has the property this repository has been
# burned by more than any other: working, it is silent; broken, it is also silent. `scripts/warnings
# selftest`, `scripts/mutate selftest` and `verify-tests-before-stop-selftest.sh` exist for that
# reason and this is the fourth. The ticket that asked for the guard said the selftest matters more
# than the guard, and it is right — a rule that reached `main` ten times while stated in plain
# language in CLAUDE.md is not going to be rescued by a second thing nobody has proved fires.
#
# WHAT IT DRIVES is the real `.githooks/commit-msg`, the real
# `.claude/hooks/no-claude-attribution.sh` and the real `scripts/lib/no-attribution.sh`, copied
# into fixtures and invoked through their real interfaces — an actual `git commit` for the first,
# an actual PreToolUse payload on stdin for the second. Never a re-implementation of their logic.
#
# WHAT IT DOES NOT COVER, stated rather than implied. It proves the two hooks refuse and allow what
# they are handed. It cannot prove Claude Code invokes the PreToolUse hook at all — that is
# `.claude/settings.json`'s wiring plus the harness's behaviour, and the only proof of it is a
# founder watching a commit be refused in a live session, which is why SONNY-406 ships a manual row
# for exactly that. A green run here with the wiring deleted would still be green.
set -u

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_SRC="$SRC_ROOT/scripts/lib/no-attribution.sh"
GITHOOK_SRC="$SRC_ROOT/.githooks/commit-msg"
CCHOOK_SRC="$SRC_ROOT/.claude/hooks/no-claude-attribution.sh"

for f in "$LIB_SRC" "$GITHOOK_SRC" "$CCHOOK_SRC"; do
  [ -r "$f" ] || { echo "selftest: cannot read $f" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
cases=0

# The forbidden shapes are assembled from parts rather than written out, for one reason worth
# stating: this file lives in the tree that `scripts/no-attribution tree` sweeps, and a fixture
# spelling a real trailer would put the very thing under audit into the audited population. The
# assembly is one join per shape and each is used verbatim below.
CO="Co-Authored-By:"
CLAUDE_ID="Claude Opus 5 (1M context) <noreply@anthropic.com>"
TRAILER="$CO $CLAUDE_ID"
OLD_TRAILER="co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>"
SESSION_LINE="Claude-Session: https://claude.ai/code/session_01AAAAAAAAAAAAAAAAAAAAAA"
FOOTER="Generated with [Claude Code](https://claude.com/claude-code)"
HUMAN_TRAILER="$CO Bhavya <bhavya@example.invalid>"
# Deliberately NOT an anthropic.com address. Every other trailer fixture here carries one, so
# without this arm the address shape answers for all of them and the co-author shape can be deleted
# from the class definition with the whole selftest still green — measured, not supposed.
TRAILER_NO_ADDR="$CO Claude <claude@example.invalid>"
# The class definition holds six shapes and a fixture usually matches several at once, so removing
# one shape leaves the selftest green while the class has genuinely narrowed. Each of the four
# below carries exactly ONE shape and nothing else, so each shape is pinned on its own. Mutation
# found this: deleting the co-author shape, and separately the generated-with shape, both left a
# 37-case run entirely green because the anthropic address and the claude-code link answered for
# them.
BARE_FOOTER="Generated with Claude Code"
SESSION_ONLY="Claude-Session: internal-ref-4417"
LINK_ONLY="See https://claude.com/claude-code for details"
ADDRESS_ONLY="Signed-off-by: someone <noreply@anthropic.com>"

new_fixture() {
  local install="${1:-install}"
  local repo="$WORK/repo.$RANDOM.$RANDOM"
  mkdir -p "$repo/.githooks" "$repo/scripts/lib" "$repo/.claude/hooks"
  cp "$LIB_SRC" "$repo/scripts/lib/no-attribution.sh"
  cp "$GITHOOK_SRC" "$repo/.githooks/commit-msg"
  cp "$CCHOOK_SRC" "$repo/.claude/hooks/no-claude-attribution.sh"
  chmod +x "$repo/.githooks/commit-msg" "$repo/.claude/hooks/no-claude-attribution.sh"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email selftest@example.invalid
  git -C "$repo" config user.name selftest
  [ "$install" = "install" ] && git -C "$repo" config core.hooksPath .githooks
  printf 'seed\n' > "$repo/seed.txt"
  git -C "$repo" add -A >/dev/null
  # --no-verify here only: the fixture must be seeded before the hook it is about to prove.
  git -C "$repo" commit -q --no-verify -m "seed"
  printf '%s' "$repo"
}

# msg <printf format> [args...] — stage the commit message this fixture will use.
msg() { printf "$@" > "$WORK/msg.txt"; }

# try_commit <repo> [mode F|m] — a real commit, through the real hook path, using the staged
# message. It deliberately takes NO pipe: `printf ... | try_commit` would run the function in a
# subshell and the exit code it records would never reach the caller, which is CLAUDE.md's rule
# about putting nothing between a command and the `$?` being reported. The first draft did exactly
# that and died on an unbound RUN_EXIT.
try_commit() {
  local repo="$1" mode="${2:-F}"
  printf 'change %s\n' "$RANDOM" >> "$repo/seed.txt"
  git -C "$repo" add -A >/dev/null
  if [ "$mode" = "F" ]; then
    git -C "$repo" commit -F "$WORK/msg.txt" > "$WORK/out" 2> "$WORK/err"
  else
    git -C "$repo" commit -m "$(cat "$WORK/msg.txt")" > "$WORK/out" 2> "$WORK/err"
  fi
  RUN_EXIT=$?
  RUN_BOTH="$(cat "$WORK/out")
$(cat "$WORK/err")"
}

# run_cchook <repo> <command text> — the real PreToolUse script, real payload on stdin.
run_cchook() {
  local repo="$1"
  CC_CMD="$2" CC_CWD="$repo" python3 -c '
import json, os
print(json.dumps({"tool_name": "Bash",
                  "tool_input": {"command": os.environ["CC_CMD"]},
                  "cwd": os.environ["CC_CWD"]}))
' > "$WORK/payload.json"
  env CLAUDE_PROJECT_DIR="$repo" bash "$repo/.claude/hooks/no-claude-attribution.sh" \
    < "$WORK/payload.json" > "$WORK/out" 2> "$WORK/err"
  RUN_EXIT=$?
  RUN_BOTH="$(cat "$WORK/out")
$(cat "$WORK/err")"
}

run_cchook_raw() {
  local repo="$1"
  printf '%s' "$2" > "$WORK/payload.json"
  env CLAUDE_PROJECT_DIR="$repo" bash "$repo/.claude/hooks/no-claude-attribution.sh" \
    < "$WORK/payload.json" > "$WORK/out" 2> "$WORK/err"
  RUN_EXIT=$?
  RUN_BOTH="$(cat "$WORK/out")
$(cat "$WORK/err")"
}

# assert <name> <expected exit> <must appear, or -> <must not appear, or ->
assert() {
  local name="$1" want_exit="$2" want="$3" avoid="$4" ok=1 why=""
  cases=$((cases + 1))
  [ "$RUN_EXIT" = "$want_exit" ] || { ok=0; why="exit $RUN_EXIT, wanted $want_exit"; }
  if [ "$want" != "-" ] && ! printf '%s' "$RUN_BOTH" | grep -qF -- "$want"; then
    ok=0; why="${why:+$why; }did not say: $want"
  fi
  if [ "$avoid" != "-" ] && printf '%s' "$RUN_BOTH" | grep -qF -- "$avoid"; then
    ok=0; why="${why:+$why; }said what it must not: $avoid"
  fi
  if [ "$ok" = 1 ]; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s — %s\n' "$name" "$why"
    printf '%s\n' "$RUN_BOTH" | sed 's/^/          /' | head -20
    failures=$((failures + 1))
  fi
}

# A refusal must leave no commit behind. An arm reading only stderr cannot tell a hook that
# refused from one that complained and committed anyway.
assert_head_subject() {
  local name="$1" repo="$2" want="$3" got
  cases=$((cases + 1))
  got="$(git -C "$repo" log -1 --format='%s' 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s — HEAD subject is "%s", wanted "%s"\n' "$name" "$got" "$want"
    failures=$((failures + 1))
  fi
}

assert_config() {
  local name="$1" repo="$2" want="$3" got
  cases=$((cases + 1))
  got="$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s — core.hooksPath is "%s", wanted "%s"\n' "$name" "$got" "$want"
    failures=$((failures + 1))
  fi
}

echo "no-claude-attribution selftest"

# ---------------------------------------------------------------------------------------------
# .githooks/commit-msg — the only barrier that reads the message git is about to commit.
#
# The positive control is first and is not a formality: a guard that refuses everything and a
# guard that refuses the right things print identical output on every refusing arm below it.
# ---------------------------------------------------------------------------------------------
echo "  -- .githooks/commit-msg"
repo="$(new_fixture)"

msg 'docs(x): SONNY-1 an ordinary commit message\n\nOne continuous paragraph.\n'
try_commit "$repo"
assert "CONTROL: an ordinary message commits" 0 - "REFUSED"
assert_head_subject "  ...and the commit is really there" "$repo" \
  "docs(x): SONNY-1 an ordinary commit message"

msg 'feat(x): SONNY-1 signed by the harness\n\nBody.\n\n%s\n' "$TRAILER"
try_commit "$repo"
assert "a co-author trailer naming Claude is refused" 1 "REFUSED" -
assert_head_subject "  ...and no commit was made" "$repo" \
  "docs(x): SONNY-1 an ordinary commit message"

msg 'feat(x): SONNY-1 the session line\n\nBody.\n\n%s\n' "$SESSION_LINE"
try_commit "$repo"
assert "a session-URL trailer is refused" 1 "REFUSED" -

msg 'feat(x): SONNY-1 the footer\n\nBody.\n\n%s\n' "$FOOTER"
try_commit "$repo"
assert "a generated-with footer is refused" 1 "REFUSED" -

msg 'feat(x): SONNY-1 the older shape\n\nBody.\n\n%s\n' "$OLD_TRAILER"
try_commit "$repo"
assert "the 2026-07-12 shape, lower-cased, is refused too" 1 "REFUSED" -

# The two arms that decide whether anyone leaves this switched on. The class is a set of
# attribution SHAPES; a guard firing on the word "Claude" would refuse most of this repository's
# own commit messages and would be gone within the week.
msg 'docs(x): SONNY-1 record why prose was not enough\n\nThe harness supplies a co-author trailer at commit time as a system-level default, CLAUDE.md contradicts it in prose, and prose lost. Three of four lanes in that wave got it right, so the rule is not unfindable.\n'
try_commit "$repo"
assert "prose ABOUT the rule still commits — the class is a shape, not a word" 0 - "REFUSED"

msg 'feat(x): SONNY-1 the footer with no link\n\nBody.\n\n%s\n' "$BARE_FOOTER"
try_commit "$repo"
assert "the generated-with shape is pinned on its own, not by the claude-code link" 1 "REFUSED" -

msg 'feat(x): SONNY-1 a session trailer with no claude.ai URL\n\nBody.\n\n%s\n' "$SESSION_ONLY"
try_commit "$repo"
assert "the session-trailer shape is pinned on its own, not by the URL" 1 "REFUSED" -

msg 'feat(x): SONNY-1 the product link alone\n\nBody.\n\n%s\n' "$LINK_ONLY"
try_commit "$repo"
assert "the claude-code link is pinned on its own" 1 "REFUSED" -

msg 'feat(x): SONNY-1 the address under another trailer name\n\nBody.\n\n%s\n' "$ADDRESS_ONLY"
try_commit "$repo"
assert "the anthropic address is pinned on its own, under any trailer name" 1 "REFUSED" -

msg 'feat(x): SONNY-1 a trailer signed at another address\n\nBody.\n\n%s\n' "$TRAILER_NO_ADDR"
try_commit "$repo"
assert "a Claude co-author trailer is refused on its own shape, not on the address" 1 "REFUSED" -

msg 'feat(x): SONNY-1 a real pair of authors\n\nBody.\n\n%s\n' "$HUMAN_TRAILER"
try_commit "$repo"
assert "a HUMAN co-author trailer still commits" 0 - "REFUSED"

# -F was every arm above. -m is the other route, and it is the one the eight commits on `main`
# were actually made by.
msg 'feat(x): SONNY-1 through dash-m instead\n\n%s\n' "$TRAILER"
try_commit "$repo" m
assert "the -m route is refused as well as -F" 1 "REFUSED" -

# Fail closed. A guard that cannot find its own definition of the class has checked nothing, and
# "nothing was checked" must never leave the same trace as "nothing was found".
repo="$(new_fixture)"
mv "$repo/scripts/lib/no-attribution.sh" "$repo/scripts/lib/moved-away.sh"
msg 'docs(x): SONNY-1 a perfectly clean message\n'
try_commit "$repo"
assert "a missing class definition REFUSES rather than passing" 1 "Nothing has been checked" -
assert_head_subject "  ...and makes no commit" "$repo" "seed"

# ---------------------------------------------------------------------------------------------
# .claude/hooks/no-claude-attribution.sh — the PreToolUse layer.
# ---------------------------------------------------------------------------------------------
echo "  -- .claude/hooks/no-claude-attribution.sh"
repo="$(new_fixture)"

run_cchook_raw "$repo" '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
assert "CONTROL: a non-Bash tool is not this hook's business" 0 - "REFUSED"

run_cchook "$repo" 'swift build'
assert "CONTROL: an unwatched Bash command passes straight through" 0 - "REFUSED"

run_cchook "$repo" 'git commit -m "docs(x): SONNY-1 an ordinary message"'
assert "CONTROL: a clean git commit is allowed" 0 - "REFUSED"

run_cchook "$repo" "git commit -m \"feat: x

$TRAILER\""
assert "a trailer in the command text is refused" 2 "REFUSED" -

run_cchook "$repo" "gh pr create --title t --body \"Summary.

$FOOTER\""
assert "a generated-with footer in a PR body is refused" 2 "REFUSED" -

run_cchook "$repo" "gh pr create --title t --body \"See https://claude.ai/code/session_01AAAAAAAAAAAAAAAAAAAAAA\""
assert "a session URL in a PR body is refused" 2 "REFUSED" -

# THE HEREDOC PAIR, and it is the reason this hook has two notions of its input at all. The first
# live action of the shipped hook was to refuse the `cat` that was writing THIS FILE, because the
# heredoc body quoted every shape above. A guard that refuses documents about the rule is a guard
# somebody switches off. The second arm is why the fix could not simply be "ignore heredocs".
run_cchook "$repo" "cat > note.txt <<'EOF'
Run: git commit -m \"feat: x\"

$TRAILER
EOF"
assert "a cat whose heredoc QUOTES a trailer is allowed — data being written, not a commit" \
  0 - "REFUSED"

run_cchook "$repo" "gh pr create --title t --body \"\$(cat <<'EOF'
Summary.

$FOOTER
EOF
)\""
assert "  ...but a PR body that COMES FROM a heredoc is still refused" 2 "REFUSED" -

# The surfaces that hide the text in a file. This is the arm that matters most for PR bodies and
# ticket content, neither of which is normally typed on a command line.
printf '<div><p>Done.</p><p>%s</p></div>\n' "$FOOTER" > "$repo/ticket.html"
run_cchook "$repo" 'scripts/plane comment SONNY-1 ticket.html'
assert "attribution inside a ticket HTML file is refused" 2 "ticket.html" -

printf 'Summary.\n\n%s\n' "$FOOTER" > "$repo/body.md"
run_cchook "$repo" 'gh pr create --title t --body-file body.md'
assert "attribution inside a --body-file is refused" 2 "body.md" -

# THE SELF-REFERENCE PAIR. The files that define the class match it, so scanning one as a "named
# file" refuses a command that merely reads it — which is what the shipped guard did to
# `. scripts/lib/no-attribution.sh` on the first command after it was committed. The exemption is
# narrow, and the second arm is what keeps it narrow: it exempts a file from being READ AS AN
# ARGUMENT and exempts nothing from the commit-msg hook.
run_cchook "$repo" '. scripts/lib/no-attribution.sh && git commit -m "docs(x): SONNY-1 clean"'
assert "a command that merely READS the class definition is not refused for quoting it" \
  0 - "REFUSED"

printf 'body\n\n%s\n' "$TRAILER" > "$repo/CLAUDE.md"
git -C "$repo" add -A >/dev/null
printf 'change %s\n' "$RANDOM" >> "$repo/seed.txt"
git -C "$repo" add -A >/dev/null
git -C "$repo" commit -F CLAUDE.md > "$WORK/out" 2> "$WORK/err"
RUN_EXIT=$?
RUN_BOTH="$(cat "$WORK/out")
$(cat "$WORK/err")"
assert "  ...but committing WITH one as the message is still refused by git" 1 "REFUSED" -

printf 'docs(x): SONNY-1 clean\n' > "$repo/clean.txt"
run_cchook "$repo" 'gh pr create --title t --body-file clean.txt'
assert "CONTROL: a clean --body-file is allowed" 0 - "REFUSED"

# --no-verify is the one route that switches the git layer off entirely, so it is refused here
# even when the message is spotless.
run_cchook "$repo" 'git commit --no-verify -m "docs(x): SONNY-1 perfectly clean"'
assert "--no-verify on a commit is refused even with a clean message" 2 "no-verify" -

run_cchook "$repo" 'git commit -n -m "docs(x): SONNY-1 perfectly clean"'
assert "  ...and so is git's short spelling of it" 2 "no-verify" -

run_cchook "$repo" 'git commit -m "docs(x): SONNY-1 clean" && echo -n done'
assert "  CONTROL: an -n belonging to another command is not refused" 0 - "REFUSED"

# The install arms: this is the answer to "a committed git hook only survives a fresh worktree if
# something sets core.hooksPath".
repo="$(new_fixture no-install)"
assert_config "CONTROL: the fixture really starts with core.hooksPath unset" "$repo" ""
run_cchook "$repo" 'git commit -m "docs(x): SONNY-1 clean"'
assert "an unset core.hooksPath is installed rather than warned about" 0 "set core.hooksPath" -
assert_config "  ...and the config really says .githooks afterwards" "$repo" ".githooks"

repo="$(new_fixture no-install)"
git -C "$repo" config core.hooksPath .somewhere-else
run_cchook "$repo" 'git commit -m "docs(x): SONNY-1 clean"'
assert "a core.hooksPath pointing elsewhere is REFUSED, never silently overwritten" \
  2 ".somewhere-else" -
assert_config "  ...and it is left exactly as it was" "$repo" ".somewhere-else"

repo="$(new_fixture)"
mv "$repo/scripts/lib/no-attribution.sh" "$repo/scripts/lib/moved-away.sh"
run_cchook "$repo" 'git commit -m "docs(x): SONNY-1 clean"'
assert "a missing class definition REFUSES a watched command" 2 "is missing from this checkout" -
run_cchook "$repo" 'swift build'
assert "  ...and still lets an unwatched one through" 0 - "REFUSED"

# ---------------------------------------------------------------------------------------------
# The two layers together. Each was proved in isolation above; this is the only arm showing that
# the config one of them installs actually arms the other.
# ---------------------------------------------------------------------------------------------
echo "  -- the two layers together"
repo="$(new_fixture no-install)"
run_cchook "$repo" 'git commit -m "docs(x): SONNY-1 clean"'
assert "the PreToolUse layer installs the config" 0 "set core.hooksPath" -
msg 'feat(x): SONNY-1 committed after the install\n\n%s\n' "$TRAILER"
try_commit "$repo"
assert "  ...and a real git commit carrying a trailer is then refused BY GIT" 1 "REFUSED" -
assert_head_subject "  ...leaving the repository on its seed commit" "$repo" "seed"

printf 'selftest: %d case(s), %d failure(s)\n' "$cases" "$failures"
[ "$failures" -eq 0 ] || exit 2

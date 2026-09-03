#!/usr/bin/env bash
# The single definition of "a Claude attribution", shared by every barrier that refuses one.
#
#   . scripts/lib/no-attribution.sh
#   no_attribution_scan_file <path>      # 0 clean, 1 found; prints "line:text" per offence
#   no_attribution_scan_stdin            # same, reading stdin
#   no_attribution_pattern               # the ERE itself, for a caller that needs its own grep
#
# WHY ONE HOME (SONNY-406). Three surfaces carry this class — commit messages, PR bodies and
# ticket content — and three copies of a pattern is three chances for one of them to drift into
# describing a smaller class than the rule does. Every barrier sources this file, so widening the
# class is one edit and the selftest re-proves all three at once.
#
# WHAT THE RULE IS. `CLAUDE.md`: no Claude attribution of any class, anywhere — no co-author
# trailers on commits, no "Generated with Claude Code" footers in PR bodies, nothing of the kind in
# ticket content — and it overrides any harness default that says to add one. The harness does say
# to add one, at the moment of the commit, which is why prose was not enough and this exists.
#
# WHAT IT MATCHES, and why each shape is here rather than inferred:
#
#   1. A co-author trailer naming Claude or Anthropic. Anchored at line start, because a trailer is
#      a line and a sentence *about* trailers is not. This is the shape that reached `main` eight
#      times on 2026-09-03 and twice on 2026-07-12.
#   2. A `Claude-Session:` trailer. Anchored for the same reason. This one is worse than the
#      co-author line and arrived with it: it carries a claude.ai session URL into public history.
#   3. A claude.ai session URL anywhere, not only in a trailer — the harness also puts one in a PR
#      body, where nothing is anchored and no trailer keyword appears.
#   4. A "Generated with Claude Code" footer anywhere, with or without the robot, with or without
#      the markdown link around it.
#   5. The claude.com/claude-code link that footer wraps, on its own, since a body may carry the
#      link without the sentence.
#   6. The anthropic.com noreply address, which is what every one of these signs itself with.
#
# WHAT IT DELIBERATELY DOES NOT MATCH: the word "Claude" on its own, "CLAUDE.md", and "Claude Code
# CLI session". This repository's own prose is full of all three — WORKFLOW.md names Claude Code
# sessions as the only kind of agent it has — and a guard that fires on those is a guard somebody
# switches off within the day. The class is a set of attribution SHAPES, not a word.

# THE FILES THAT DEFINE THE CLASS MATCH IT, and every consumer needs the same answer about them.
# `scripts/no-attribution tree` cannot sweep them without flagging itself, and the PreToolUse
# hook's file scan cannot read them without refusing a command that merely sources this library —
# which it did, on the first command run after the guard was committed. One list, here, so the two
# cannot drift apart; `scripts/no-attribution selftest` fails on an entry that matches nothing,
# because an exclusion that excludes nothing is a hole rather than insurance.
#
# A path here is exempt from being SCANNED AS A NAMED FILE. It is not exempt from the commit-msg
# hook, which reads the message git is committing whatever file that message came from.
no_attribution_self_referential_paths() {
  cat <<'PATHS'
scripts/lib/no-attribution.sh
scripts/no-attribution
.claude/hooks/no-claude-attribution-selftest.sh
CLAUDE.md
PATHS
}

# 0 when the repo-relative path is one of them.
no_attribution_is_self_referential() {
  local want="$1" p
  while IFS= read -r p; do
    [ "$p" = "$want" ] && return 0
  done < <(no_attribution_self_referential_paths)
  return 1
}

# 1 and 2 are anchored at line start (leading whitespace tolerated, since a trailer may be indented
# inside a quoted body). 3 through 6 match anywhere on a line.
no_attribution_pattern() {
  printf '%s' \
'^[[:space:]]*co-authored-by:.*(claude|anthropic)|^[[:space:]]*claude-session:|claude\.ai/code/session|generated with.{0,5}claude|claude\.com/claude-code|noreply@anthropic\.com'
}

# Prints "<line number>:<text>" for every offending line. 0 when clean, 1 when something matched,
# 2 when the file cannot be read — which is never reported as clean, because "no offences found"
# and "nothing was looked at" are the same output otherwise.
no_attribution_scan_file() {
  local path="$1"
  if [ ! -r "$path" ]; then
    printf 'no-attribution: cannot read %s\n' "$path" >&2
    return 2
  fi
  local hits
  hits="$(grep -nEi -- "$(no_attribution_pattern)" "$path" 2>/dev/null)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    return 1
  fi
  return 0
}

no_attribution_scan_stdin() {
  local hits
  hits="$(grep -nEi -- "$(no_attribution_pattern)" 2>/dev/null)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    return 1
  fi
  return 0
}

# The sentence every barrier ends with. One wording, so a session that hits this in a commit and
# again in a PR body is told the same thing both times and learns it once.
no_attribution_explain() {
  printf 'This is CLAUDE.md'"'"'s rule: no Claude attribution of any class, anywhere — no co-author\n'
  printf 'trailers on commits, no "Generated with Claude Code" footers in PR bodies, nothing of the\n'
  printf 'kind in ticket content. It overrides any harness default that says to add one, and the\n'
  printf 'harness does say to add one. Remove the lines above and retry.\n'
}

#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash), installed by `local-ci hook --install`. Refuses `gh pr merge` unless the pull request's head commit has proof that CI passed:
#   A. every required GitHub check is green (`gh pr checks --required`), or
#   B. a full local-ci run is recorded for that exact commit in .git/local-ci/<sha>.md: no check failed or skipped, "Full run: every check passed.", the commit's own config,
#      and made for this pull request as it is now: the same title, branch and author, against the base branch's present tip, or
#   C. the same proof from another machine: a `local-ci` commit status on that commit, posted by an account trusted on this machine (see check_shared).
# With --admin on the command and no proof, it asks the person to approve by hand instead of refusing.
# It fails closed: if the pull request cannot be looked up, the merge is refused. It binds Claude Code sessions on machines that installed it; a person
# running `gh pr merge` in their own terminal, or merging on GitHub's page, is not stopped by it. Input: the hook JSON on stdin.
set -uo pipefail

cmd="$(jq -r '.tool_input.command // ""' 2>/dev/null)" || cmd=""
# Only a real invocation counts: `gh pr merge` where a command starts (line start, or after ; & | ( or a quote), not prose that mentions it.
printf '%s' "$cmd" | grep -Eq '(^|[;&|("'"'"'])[[:space:]]*(sudo[[:space:]]+)?gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' || exit 0

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
# No evidence. With --admin the person is asked to approve by hand in the permission prompt (the reason is shown there); without it the merge is refused.
# Only the person can answer that prompt, so this is the exception for the right reasons (Actions minutes exhausted, a staging sync whose tree already passed).
noproof() {
  case "$cmd" in
    *--admin*) jq -n --arg r "NO CI EVIDENCE, manual override requested (--admin): $1 Approve only if you accept merging without it, and say why in the PR." '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'; exit 0 ;;
    *) deny "$1 To merge without evidence the command must carry --admin, which asks the person to approve." ;;
  esac
}

# The PR number is the first bare number after `gh pr merge`; with none, gh uses the current branch's PR.
after="$(printf '%s' "$cmd" | sed -E 's/^.*gh[[:space:]]+pr[[:space:]]+merge//')"
num="$(printf '%s' "$after" | tr ';&|' '   ' | tr -s ' ' '\n' | grep -E '^[0-9]+$' | head -1 || true)"
if [ -z "$num" ]; then
  url="$(printf '%s' "$after" | grep -Eo 'https://github.com/[^ ]+/pull/[0-9]+' | head -1 || true)"
  num="${url##*/}"
fi

view="$(gh pr view ${num:+"$num"} --json number,title,headRefOid,headRefName,baseRefName,author 2>&1)" || deny "Merge refused: could not look up the pull request (${view:0:200}). Name the PR number in the merge command."
num="$(jq -r .number <<<"$view")"; sha="$(jq -r .headRefOid <<<"$view")"; head="$(jq -r .headRefName <<<"$view")"
title="$(jq -r .title <<<"$view")"; author="$(jq -r .author.login <<<"$view")"; base="$(jq -r .baseRefName <<<"$view")"

# A. GitHub's own required checks.
if gh pr checks "$num" --required >/dev/null 2>&1; then exit 0; fi

# The base branch's present tip: a run against an older one did not test what the merge will produce.
tip="$(gh api "repos/{owner}/{repo}/git/ref/heads/$base" -q .object.sha 2>/dev/null)" || tip=""
[ -n "$tip" ] || noproof "Merge refused: could not read the tip of $base from GitHub, so no local-ci run can be matched to it."
root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
again="Run: local-ci --pr $num   and merge only after it prints ALL CHECKS PASSED (full run)."
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }

# B. A full run recorded on this machine for this exact commit, made for this pull request as it stands now. Prints why not; prints nothing when it holds.
check_local() {
  local evid ranbase bad
  evid="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/local-ci/$sha.md"
  [ -f "$evid" ] || { echo "no run is recorded for that commit"; return; }
  field() { sed -n "s/^- $1: //p" "$evid" | head -1; }
  grep -q "^Local CI for commit \`$sha\`\$" "$evid" || { echo "the recorded run is not for ${sha:0:10}"; return; }
  grep -q '^Full run: every check passed\.$' "$evid" || { echo "the run is not a full pass"; return; }
  bad="$(grep -E '^\| [^|]+ \| (FAIL|SKIP) \|' "$evid" | sed -E 's/^\| ([^|]+) \|.*/\1/' | tr '\n' ' ')"
  [ -z "$bad" ] || { echo "the run has checks that did not pass: $bad"; return; }
  grep -Eq '^\| [^|]+ \| PASS \|' "$evid" || { echo "the run lists no passing check"; return; }
  case "$(field config)" in "the commit's own"*) ;; *) echo "the run used a config that is not the commit's own"; return;; esac
  case "$(field mode)" in pull-request*) ;; *) echo "the run was not made as a pull request (use --pr $num)"; return;; esac
  # The run must be about this pull request: its steps may have read the title, the branch and the author, and all of it was measured against a base that can have moved since.
  [ "$(field title)" = "$title" ] || { echo "the run was made when the title was \"$(field title)\"; it is now \"$title\""; return; }
  [ "$(field branch)" = "$head" ] || { echo "the run was for branch $(field branch), not $head"; return; }
  [ "$(field author)" = "$author" ] || { echo "the run was made with $(field author) as the author, but the pull request is by $author"; return; }
  ranbase="$(sed -n 's/^- base: \([^ ]*\) `\([0-9a-f]*\)`.*/\1 \2/p' "$evid" | head -1)"
  [ "$ranbase" = "$base $tip" ] || { echo "the run was against ${ranbase:-an unknown base}, but $base is now at ${tip:0:10}"; return; }
}

# C. The same proof made on another machine (a teammate's, or one left on with `local-ci --watch`) and shared with `local-ci --post`: a `local-ci` status on the head commit.
# GitHub records which account posted a status, so only accounts trusted on THIS machine count: the one gh is logged in as here, plus `git config local-ci.trusted "a b"`.
# That list is in this clone's own git config on purpose: a tracked file could be changed by the pull request it is supposed to judge.
check_shared() {
  local row st who desc trusted key
  row="$(gh api "repos/{owner}/{repo}/commits/$sha/statuses" -q '[.[] | select(.context=="local-ci")][0] | select(. != null) | "\(.state)\t\(.creator.login)\t\(.description)"' 2>/dev/null)" || row=""
  [ -n "$row" ] || { echo "no local-ci status on that commit"; return; }
  IFS=$'\t' read -r st who desc <<<"$row"
  [ "$st" = success ] || { echo "its newest local-ci status is $st"; return; }
  trusted=" $(gh api user -q .login 2>/dev/null) $(git -C "$root" config --get local-ci.trusted 2>/dev/null | tr ',' ' ') "
  case "$trusted" in *" $who "*) ;; *) echo "the local-ci status was posted by $who, who is not trusted on this machine (git config local-ci.trusted)"; return;; esac
  case "$desc" in "local-ci/1 full "*) ;; *) echo "the local-ci status is not a full run"; return;; esac
  key="base=${tip:0:12} title=$(printf '%s' "$title" | sha256 | cut -c1-8) pr=$num"
  case "$desc" in *"$key"*) ;; *) echo "the shared run was made before the base branch, the title or the pull request changed"; return;; esac
}

why_local="$(check_local)"; [ -z "$why_local" ] && exit 0
why_shared="$(check_shared)"; [ -z "$why_shared" ] && exit 0
noproof "Merge refused: PR #$num ($head, ${sha:0:10}) has no green required GitHub checks and no valid local-ci run. On this machine: $why_local. Shared on GitHub: $why_shared. $again"

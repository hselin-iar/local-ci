#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash), installed by `local-ci hook --install`. Refuses `gh pr merge` unless the pull request's head commit has proof that CI passed:
#   A. every required GitHub check is green (`gh pr checks --required`), or
#   B. a full local-ci run is recorded for that exact commit in .git/local-ci/<sha>.md: no check failed or skipped, "Full run: every check passed.", made for this
#      pull request as it is now (the same title, branch and author, against the base branch's present tip) with the base branch's own .local-ci/config, or
#   C. the same proof from another machine: a `local-ci` commit status on that commit, posted by an account trusted on this machine (see check_shared).
# With --admin on the command and no proof, it asks the person to approve by hand instead of refusing.
#
# It is strict about the command so that what it checked is what gets merged: one merge per command, the pull request's number first, and
# --match-head-commit <the commit it checked>. Merging through `gh api` is refused. If it cannot read the command or look the pull request up, it refuses.
# Limits: it binds Claude Code sessions on machines that installed it; a person merging in their own terminal or on GitHub's page is not stopped. It reads the command
# as text, so a command that merely says the merge command outside backticks is refused too, and a merge hidden in a variable or a script file is not seen. The
# evidence is a file in .git and a status on GitHub, both of which a session could write by hand: the hook stops a merge whose run was skipped, forgotten or stale,
# not a session set on deceiving it.
# Tests: tests/hook.sh. Input: the hook JSON on stdin.
set -uo pipefail

in="$(cat)"
refuse_raw() { printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Merge refused: the merge hook could not read the command (it needs jq and the hook JSON). Nothing that looks like a merge is let through."}}'; }
if ! command -v jq >/dev/null 2>&1 || ! cmd="$(printf '%s' "$in" | jq -er '.tool_input.command' 2>/dev/null)"; then
  grep -Eq 'gh[^;&|]*[[:space:]](pr[[:space:]]+merge|api[[:space:]][^;&|]*/merge)' <<<"$in" && refuse_raw
  exit 0
fi

# A merge is `gh`, as a word (bare, by its path, after timeout, nohup, env, a VAR=value prefix, `then`, a pipe to xargs, inside $( ) or backticks, anything), then
# pr merge, with gh's -R/--repo allowed in between. The one thing taken for prose is the bare name of the command in backticks, with nothing after `merge`. A sentence that
# says more than that is refused as well: that errs on the safe side, and such text can be written with the file tools instead of the shell.
# The text is always handed to grep and sed as a here-string, never through a pipe: with pipefail, a writer cut short by `grep -q` on a long command would look like
# "no match" and let the merge through.
GHWORD="(^|[^A-Za-z0-9_.-])gh([[:space:]]+(-R|--repo)[[:space:]=]+[^[:space:]]+)*[[:space:]]+"
scan="$(sed -E 's/`gh[[:space:]]+pr[[:space:]]+merge`//g' <<<"$cmd")"
deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
if grep -Eq "${GHWORD}api[[:space:]][^;&|]*pulls/[0-9]+/merge" <<<"$scan"; then deny "Merge refused: merge with: gh pr merge <number> --match-head-commit <sha>, so the CI evidence can be checked. Merging through gh api is not allowed."; fi
grep -Eq "${GHWORD}pr[[:space:]]+merge([[:space:]]|\`|\$)" <<<"$scan" || exit 0

# No evidence. With --admin the person is asked to approve by hand in the permission prompt (the reason is shown there); without it the merge is refused.
# Only the person can answer that prompt, so this is the exception for the right reasons (Actions minutes exhausted, a pull request that changes its own checks).
noproof() {
  case "$cmd" in
    *--admin*) jq -n --arg r "NO VALID CI EVIDENCE, manual override requested (--admin): $1 Approve only if you accept merging without it, and say why in the PR." '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'; exit 0 ;;
    *) deny "$1 To merge without evidence the command must carry --admin, which asks the person to approve." ;;
  esac
}

# Exactly one merge, and its first word is the pull request's number. Anything else (a branch name, no number, options first, two merges) could make this hook
# look at one pull request while the command merges another.
[ "$(grep -oE "pr[[:space:]]+merge([[:space:]]|\`|\$)" <<<"$scan" | wc -l | tr -d ' ')" = 1 ] || deny "Merge refused: one merge per command, so that the pull request checked is the one merged."
num="$(sed -nE 's/.*pr[[:space:]]+merge[[:space:]]+([^[:space:]]+).*/\1/p' <<<"$scan" | head -1)"
case "$num" in ''|*[!0-9]*) deny "Merge refused: put the pull request's number first: gh pr merge <number> --squash --match-head-commit <sha>. A branch name, a URL or options before the number are not accepted.";; esac

view="$(gh pr view "$num" --json number,title,headRefOid,headRefName,baseRefName,author 2>&1)" || deny "Merge refused: could not look up pull request #$num (${view:0:200})."
sha="$(jq -r .headRefOid <<<"$view")"; head="$(jq -r .headRefName <<<"$view")"
title="$(jq -r .title <<<"$view")"; author="$(jq -r .author.login <<<"$view")"; base="$(jq -r .baseRefName <<<"$view")"
# The merge must be pinned to the commit this hook checks: a push between this check and the merge would otherwise merge a commit nothing has tested.
case "$cmd" in *"--match-head-commit $sha"*|*"--match-head-commit=$sha"*) ;; *) deny "Merge refused: add --match-head-commit $sha to the command, so that exactly the commit that was checked is merged.";; esac

# A. GitHub's own required checks: at least one, every one passed. A `local-ci` status does not count here even if it has been made a required check: anyone who can
# push can post one, so it is judged below (C), where the hook looks at who posted it and what it was measured against.
if [ "$(gh pr checks "$num" --required --json name,bucket -q '[.[] | select(.name != "local-ci")] | length > 0 and all(.bucket == "pass")' 2>/dev/null)" = true ]; then exit 0; fi

# The base branch's present tip: a run against an older one did not test what the merge will produce.
tip="$(gh api "repos/{owner}/{repo}/git/ref/heads/$base" -q .object.sha 2>/dev/null)" || tip=""
[ -n "$tip" ] || noproof "Merge refused: could not read the tip of $base from GitHub, so no local-ci run can be matched to it."
root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
again="Run: local-ci --pr $num   and merge only after it prints ALL CHECKS PASSED (full run)."
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }
# The checks as the base branch declares them. A run always uses the config of the commit it tests, so a pull request that edits .local-ci/config is judged by its own
# edits: it could drop a check and then pass. Such a run is not proof; with --admin the person decides.
[ "$(git -C "$root" rev-parse -q --verify "refs/remotes/origin/$base" 2>/dev/null)" = "$tip" ] || git -C "$root" fetch -q origin "$base" 2>/dev/null
basecfg=""; [ "$(git -C "$root" rev-parse -q --verify "refs/remotes/origin/$base" 2>/dev/null)" = "$tip" ] && basecfg="$(git -C "$root" show "origin/$base:.local-ci/config" 2>/dev/null | sha256)"
changed="the run used a .local-ci/config that is not $base's (this pull request changes its own checks), so what judged it has not been reviewed"

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
  case "$(field config)" in "the commit's own"*) ;; *) echo "the run used a trial config, not the commit's own"; return;; esac
  case "$(field mode)" in pull-request*) ;; *) echo "the run was not made as a pull request (use --pr $num)"; return;; esac
  # The run must be about this pull request: its steps may have read the title, the branch and the author, and all of it was measured against a base that can have moved since.
  [ "$(field title)" = "$title" ] || { echo "the run was made when the title was \"$(field title)\"; it is now \"$title\""; return; }
  [ "$(field branch)" = "$head" ] || { echo "the run was for branch $(field branch), not $head"; return; }
  [ "$(field author)" = "$author" ] || { echo "the run was made with $(field author) as the author, but the pull request is by $author"; return; }
  ranbase="$(sed -n 's/^- base: \([^ ]*\) `\([0-9a-f]*\)`.*/\1 \2/p' "$evid" | head -1)"
  [ "$ranbase" = "$base $tip" ] || { echo "the run was against ${ranbase:-an unknown base}, but $base is now at ${tip:0:10}"; return; }
  [ -n "$basecfg" ] && [ "$(field config-sha256)" = "$basecfg" ] || { echo "$changed"; return; }
}

# C. The same proof made on another machine (a teammate's, or one left on with `local-ci --watch`) and shared with `local-ci --post`: a `local-ci` status on the head commit.
# GitHub records which account posted a status, so only accounts trusted on THIS machine count: the one gh is logged in as here, plus `git config local-ci.trusted "a b"`.
# That list is in this clone's own git config on purpose: a tracked file could be changed by the pull request it is supposed to judge.
check_shared() {
  local row st who desc trusted
  row="$(gh api "repos/{owner}/{repo}/commits/$sha/statuses" -q '[.[] | select(.context=="local-ci")][0] | select(. != null) | "\(.state)\t\(.creator.login)\t\(.description)"' 2>/dev/null)" || row=""
  [ -n "$row" ] || { echo "no local-ci status on that commit"; return; }
  IFS=$'\t' read -r st who desc <<<"$row"
  [ "$st" = success ] || { echo "its newest local-ci status is $st"; return; }
  trusted=" $(gh api user -q .login 2>/dev/null) $(git -C "$root" config --get local-ci.trusted 2>/dev/null | tr ',' ' ') "
  case "$trusted" in *" $who "*) ;; *) echo "the local-ci status was posted by $who, who is not trusted on this machine (git config local-ci.trusted)"; return;; esac
  case "$desc" in "local-ci/1 full "*) ;; *) echo "the local-ci status is not a full run"; return;; esac
  # Each part is matched whole, up to the space that ends it: pr=10 must not pass for pr=101.
  case " $desc " in *" base=${tip:0:12} title=$(printf '%s' "$title" | sha256 | cut -c1-8) pr=$num "*) ;; *) echo "the shared run was made before the base branch, the title or the pull request changed"; return;; esac
  [ -n "$basecfg" ] || { echo "$changed"; return; }
  case " $desc " in *" cfg=${basecfg:0:8} "*) ;; *) echo "$changed"; return;; esac
}

why_local="$(check_local)"; [ -z "$why_local" ] && exit 0
why_shared="$(check_shared)"; [ -z "$why_shared" ] && exit 0
noproof "Merge refused: PR #$num ($head, ${sha:0:10}) has no green required GitHub checks and no valid local-ci run. On this machine: $why_local. Shared on GitHub: $why_shared. $again"

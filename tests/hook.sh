#!/usr/bin/env bash
# Tests for hooks/require-ci-before-merge.sh. A stand-in `gh` answers from canned data and a throwaway repository holds the evidence, so nothing here talks to GitHub.
# Run it after any change to the hook:   tests/hook.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; HOOK="$HERE/hooks/require-ci-before-merge.sh"
T="$(mktemp -d /tmp/local-ci-hooktest.XXXXXX)"; trap 'rm -rf "$T"' EXIT
M="gh pr"; M="$M merge"   # built here so that this file can be written and run by a session the hook is watching
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }

# The repository the hook looks at: its origin/main carries the config, as a real one does.
R="$T/repo"; mkdir -p "$R/.local-ci" && cd "$R" && git init -q -b main . && git config user.email t@localhost && git config user.name t
cp "$HERE/templates/node" .local-ci/config && git add -A && git commit -qm base && git update-ref refs/remotes/origin/main HEAD
TIP="$(git rev-parse HEAD)"; TOOL="$(sha256 < .local-ci/config)"
SHA=bbbbbbbbbb0000000000000000000000000000aa; TITLE="Some title"; TH="$(printf '%s' "$TITLE" | sha256 | cut -c1-8)"
CHECKS="merge install unit build gitleaks semgrep"
evidence() {   # writes a good run; arguments are sed expressions that spoil it
  local f="$R/.git/local-ci/$SHA.md" c e; mkdir -p "$R/.git/local-ci"
  { echo "Local CI for commit \`$SHA\`"; echo; echo "- tree: \`x\`"; echo "- mode: pull-request #777"; echo "- title: $TITLE"; echo "- branch: feature/x"; echo "- author: octocat"
    echo "- base: main \`$TIP\`, fetched from origin for this run; the commit is 1 ahead and contains it: yes"; echo "- config: the commit's own .local-ci/config"; echo "- config-sha256: $TOOL"; echo; echo "| check | result | seconds | detail |"; echo "|---|---|---|---|"
    for c in $CHECKS; do echo "| $c | PASS | 1 |  |"; done; echo; echo "Full run: every check passed."; } > "$f"
  for e in "$@"; do sed -i.bak -E "$e" "$f"; done; rm -f "$f.bak"
}
mkdir "$T/bin"; cat > "$T/bin/gh" <<STUB
#!/usr/bin/env bash
q=""; prev=""; for a in "\$@"; do [ "\$prev" = "-q" ] && q="\$a"; prev="\$a"; done
out() { if [ -n "\$q" ]; then jq -r "\$q"; else cat; fi; }
case "\$1 \$2" in
  "pr view") [ "\$3" = 777 ] || { echo "no pull requests found" >&2; exit 1; }
     jq -n --arg t "\${STUB_TITLE:-$TITLE}" '{number:777,title:\$t,headRefOid:"$SHA",headRefName:"feature/x",baseRefName:"main",author:{login:"octocat"}}' | out;;
  "pr checks") echo "\${STUB_CHECKS:-[{\"name\":\"test\",\"bucket\":\"fail\"}]}" | out;;
  "api user") echo '{"login":"octocat"}' | out;;
  "api "*"/statuses") echo "\${STUB_STATUSES:-[]}" | out;;
  "api "*"git/ref"*) echo "{\"object\":{\"sha\":\"\${STUB_TIP:-$TIP}\"}}" | out;;
esac
STUB
chmod +x "$T/bin/gh"

PASSED=0; FAILED=0
decide() { printf '%s' "$(jq -n --arg c "$1" '{tool_input:{command:$c}}')" | PATH="$T/bin:$PATH" CLAUDE_PROJECT_DIR="$R" bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput | "\(.permissionDecision) \(.permissionDecisionReason)"' 2>/dev/null; }
# expect <what> <allow|deny|ask> <text the reason must contain> <command>
expect() { local got; got="$(decide "$4")"; [ -n "$got" ] || got="allow"
  if [ "${got%% *}" = "$2" ] && case "$got" in *"$3"*) true;; *) false;; esac; then PASSED=$((PASSED + 1)); else FAILED=$((FAILED + 1)); echo "  WRONG $1: wanted $2 ($3), got: ${got:0:170}"; fi; }
OK="--squash --match-head-commit $SHA"

echo "what counts as a merge"
evidence
expect "a plain merge with evidence"            allow "" "$M 777 $OK"
expect "not a merge: a view"                    allow "" "gh pr view 777"
expect "not a merge: prose in backticks"        allow "" "echo \"never run \`$M\` by hand\""
rm -f "$R/.git/local-ci/$SHA.md"
expect "after &&"                               deny "no run is recorded" "cd /x && $M 777 $OK"
expect "with an environment prefix"             deny "no run is recorded" "GH_PAGER= $M 777 $OK"
expect "with -R before pr"                      deny "no run is recorded" "gh -R owner/repo pr merge 777 $OK"
expect "inside if ... then"                     deny "no run is recorded" "if true; then $M 777 $OK; fi"
expect "inside bash -c"                         deny "no run is recorded" "bash -c '$M 777 $OK'"
expect "on a later line"                        deny "no run is recorded" "sleep 5
$M 777 $OK"
expect "through the API"                        deny "gh pr merge" "gh api -X PUT repos/o/r/pulls/777/merge"
expect "gh called by its path"                  deny "no run is recorded" "/opt/homebrew/bin/$M 777 $OK"
expect "behind timeout"                         deny "no run is recorded" "timeout 60 $M 777 $OK"
expect "behind nohup, in the background"        deny "no run is recorded" "nohup $M 777 $OK &"
expect "fed by xargs"                           deny "number first" "echo 777 | xargs $M"
expect "a sentence that says it, outside backticks, is refused too (the safe side)" deny "number first" "echo we may $M later"

echo "which pull request"
evidence
expect "the number must come first"             deny "number first" "$M --squash --subject \"Step 3 of 5\" 777 --match-head-commit $SHA"
expect "a branch name is not a number"          deny "number first" "$M feature/x $OK"
expect "no number at all"                       deny "number first" "$M $OK"
expect "two merges in one command"              deny "one merge" "$M 777 $OK && $M 778 $OK"
expect "the merge must be pinned to the commit" deny "match-head-commit" "$M 777 --squash"
expect "pinned to another commit"               deny "match-head-commit" "$M 777 --squash --match-head-commit cccccccccc0000000000000000000000000000aa"
expect "an unknown pull request"                deny "could not look up" "$M 999 $OK"

echo "the evidence on this machine"
evidence;                                             expect "a good run"                    allow "" "$M 777 $OK"
rm -f "$R/.git/local-ci/$SHA.md"
STUB_CHECKS='[{"name":"test","bucket":"pass"},{"name":"lint","bucket":"pass"}]' expect "green GitHub checks need no run" allow "" "$M 777 $OK"
STUB_CHECKS='[{"name":"test","bucket":"pass"},{"name":"lint","bucket":"pending"}]' expect "a pending GitHub check is not green" deny "no run is recorded" "$M 777 $OK"
STUB_CHECKS='[{"name":"local-ci","bucket":"pass"}]' expect "a posted local-ci status made a required check is not GitHub's own checks" deny "no run is recorded" "$M 777 $OK"
STUB_CHECKS='[]' expect "no required checks at all is not green" deny "no run is recorded" "$M 777 $OK"
evidence 's/\| semgrep \| PASS/| semgrep | FAIL/';     expect "a check that did not pass"     deny "did not pass: semgrep" "$M 777 $OK"
evidence 's/\| unit \| PASS/| unit | SKIP/';           expect "a check that was skipped"      deny "did not pass: unit" "$M 777 $OK"
evidence "s/^- config: .*/- config: \/tmp\/x, NOT the commit's own (--config)/"; expect "a trial config" deny "trial config" "$M 777 $OK"
evidence 's/^- mode: .*/- mode: push/';                expect "a run that was not a pull request" deny "not made as a pull request" "$M 777 $OK"
evidence 's/^Full run: every check passed\./Partial run: the 5 of 6 checks that ran passed. This is not merge evidence./'; expect "a partial run" deny "not a full pass" "$M 777 $OK"
evidence "s/$SHA/cccccccccc0000000000000000000000000000aa/"; expect "a run for another commit" deny "not for" "$M 777 $OK"
evidence;                         STUB_TITLE="New title" expect "retitled since the run"       deny "title" "$M 777 $OK"
evidence 's/^- author: .*/- author: someone-else/';    expect "checked as another author"     deny "someone-else as the author" "$M 777 $OK"
evidence "s/^- base: main \`[0-9a-f]+\`/- base: main \`2222222222222222222222222222222222222222\`/"; expect "the base moved since" deny "is now at" "$M 777 $OK"
evidence 's/^- config-sha256: .*/- config-sha256: 0000000000000000000000000000000000000000000000000000000000000000/'; expect "a pull request that changed its own checks" deny "changes its own checks" "$M 777 $OK"
expect "the same, with --admin: the person is asked"   ask "changes its own checks" "$M 777 $OK --admin"
rm -f "$R/.git/local-ci/$SHA.md";                      expect "no run, with --admin: the person is asked" ask "no run is recorded" "$M 777 $OK --admin"

echo "evidence shared from another machine"
st() { echo "[{\"context\":\"local-ci\",\"state\":\"$1\",\"creator\":{\"login\":\"$2\"},\"description\":\"$3\"}]"; }
KEY="base=${TIP:0:12} title=$TH pr=777 cfg=${TOOL:0:8}"
STUB_STATUSES="$(st success octocat "local-ci/1 full 6/6 $KEY arm64 3m")"       expect "posted by this account"        allow "" "$M 777 $OK"
STUB_STATUSES="$(st success stranger "local-ci/1 full 6/6 $KEY arm64 3m")"         expect "posted by an untrusted account" deny "not trusted" "$M 777 $OK"
git -C "$R" config local-ci.trusted "stranger"
STUB_STATUSES="$(st success stranger "local-ci/1 full 6/6 $KEY arm64 3m")"         expect "that account, once trusted"    allow "" "$M 777 $OK"
git -C "$R" config --unset local-ci.trusted
STUB_STATUSES="$(st failure octocat "local-ci/1 fail $KEY aarch64 1 failed: unit")"  expect "a posted failure"              deny "is failure" "$M 777 $OK"
STUB_STATUSES="$(st success octocat "all good")"                                     expect "a hand-typed success"          deny "not a full run" "$M 777 $OK"
STUB_STATUSES="$(st success octocat "local-ci/1 full 6/6 base=${TIP:0:12} title=$TH pr=7771 cfg=${TOOL:0:8} arm64 3m")" expect "a result for pull request 7771 is not one for 777" deny "changed" "$M 777 $OK"
STUB_STATUSES="$(st success octocat "local-ci/1 full 6/6 base=${TIP:0:12} title=$TH pr=777 cfg=00000000 arm64 3m")"     expect "shared, made with a changed config"   deny "changes its own checks" "$M 777 $OK"

echo "when the command cannot be read"
got="$(printf '%s' "not json but mentions $M 777" | PATH="$T/bin:$PATH" CLAUDE_PROJECT_DIR="$R" bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)"
[ "$got" = deny ] && PASSED=$((PASSED + 1)) || { FAILED=$((FAILED + 1)); echo "  WRONG unreadable input that mentions a merge: wanted deny, got: ${got:-allow}"; }
got="$(printf '%s' "not json, nothing to see" | PATH="$T/bin:$PATH" CLAUDE_PROJECT_DIR="$R" bash "$HOOK" 2>/dev/null)"
[ -z "$got" ] && PASSED=$((PASSED + 1)) || { FAILED=$((FAILED + 1)); echo "  WRONG unreadable input with no merge: wanted nothing, got: $got"; }

echo; echo "$PASSED ok, $FAILED wrong"; [ "$FAILED" = 0 ]

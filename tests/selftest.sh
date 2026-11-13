#!/usr/bin/env bash
# Proves local-ci on a toy project: a clean commit passes, and each kind of defect turns the run red. Needs Docker; takes a few minutes; touches nothing outside a temp folder.
#   tests/selftest.sh
set -uo pipefail
TOOL="$(cd "$(dirname "$0")/.." && pwd)"; LCI="$TOOL/local-ci"
T="$(mktemp -d /tmp/local-ci-selftest.XXXXXX)"; trap 'rm -rf "$T" /tmp/local-ci/selftest-toy' EXIT
PASSED=0; FAILED=0
ok()  { PASSED=$((PASSED + 1)); echo "  ok    $1"; }
bad() { FAILED=$((FAILED + 1)); echo "  WRONG $1"; sed 's/^/        /' "$T/out" | tail -12; }
# expect <what> <exit code> <text the output must contain> -- local-ci arguments
expect() { local what=$1 rc=$2 text=$3; shift 4; (cd "$T/toy" && "$LCI" "$@") >"$T/out" 2>&1; local got=$?
  if [ "$got" = "$rc" ] && grep -qF -- "$text" "$T/out"; then ok "$what"; else bad "$what (exit $got, wanted $rc and: $text)"; fi; }

mkdir "$T/toy" && cd "$T/toy" && git init -q -b main . && git config user.email selftest@localhost && git config user.name selftest
cat > package.json <<'J'
{ "name": "toy", "version": "1.0.0", "private": true, "scripts": { "test": "node --test" } }
J
cat > package-lock.json <<'J'
{ "name": "toy", "version": "1.0.0", "lockfileVersion": 3, "requires": true, "packages": { "": { "name": "toy", "version": "1.0.0" } } }
J
mkdir test && cat > test/sum.test.js <<'J'
const { test } = require('node:test'); const assert = require('node:assert');
test('adds', () => assert.equal(1 + 1, 2));
test('adds again', () => assert.equal(2 + 2, 4));
J
mkdir .local-ci && cat > .local-ci/config <<'C'
name selftest-toy
image node:24-bookworm
user node
home /home/node
cache /home/node/.npm
install npm ci
service postgres postgres:17
  env POSTGRES_PASSWORD=toy
  health pg_isready -U postgres
job unit
  step unit: npm test && touch leftover-from-job-unit
    tests node
  step whoami: test "$(id -un)" = node && echo "runs as an ordinary user"
    expect runs as an ordinary user
job database
  uses postgres
  env PGHOST=127.0.0.1
  step fresh-checkout: test ! -e leftover-from-job-unit
  step reaches-db: node -e "require('net').connect(5432, process.env.PGHOST).on('connect', () => { console.log('database answered'); process.exit(0) }).on('error', (e) => { console.error(e.message); process.exit(1) })"
    expect database answered
  step title: test -n "$PR_TITLE" && echo "title is $PR_TITLE"
    pr-only
scan gitleaks
C
git add -A && git commit -qm "a clean toy project"; GOOD="$(git rev-parse HEAD)"

echo "local-ci selftest"
expect "a clean commit passes, in full"                    0 "ALL CHECKS PASSED" -- 
expect "the summary is kept where the merge hook reads it" 0 "selftest-toy" -- --only whoami
[ -f ".git/local-ci/$GOOD.md" ] && grep -q "^- config: the commit's own" ".git/local-ci/$GOOD.md" && ok "evidence file written" || bad "evidence file written"
expect "a partial run says it is not merge evidence"       0 "not merge evidence" -- --only unit
expect "an unknown check name is refused"                  2 "unknown check" -- --only unti

git checkout -q -b failing-test "$GOOD"; echo "require('node:test').test('fails', () => { throw new Error('planted') });" > test/bad.test.js; git add -A; git commit -qm "a failing test"
expect "a failing test fails the run"                      1 "CHECK(S) FAILED: unit" -- --only unit

git checkout -q -b no-tests "$GOOD"; git rm -q test/sum.test.js; git commit -qm "no tests left"
expect "a test step that runs no tests fails"              1 "no tests ran" -- --only unit

git checkout -q -b leaked "$GOOD"; printf 'const token = "ghp_%s";\n' "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)" > leak.js; git add -A; git commit -qm "a committed token"
expect "a committed token fails the secret scan"           1 "CHECK(S) FAILED: gitleaks" -- --only gitleaks
expect "as a pull request, only its own commits are scanned, and found" 1 "CHECK(S) FAILED: gitleaks" -- --only gitleaks --title "leak"

# The base branch moves on after the branch was cut: a pull request is tested as the merge of the two, as hosted CI does.
git checkout -q main; echo "require('node:test').test('new on main', () => { throw new Error('main broke it') });" > test/main.test.js; git add -A; git commit -qm "main gains a failing test"
git checkout -q -b behind "$GOOD"; echo "// harmless" > extra.js; git add -A; git commit -qm "a harmless change, cut before main moved"
expect "a pull request behind its base is tested merged with it" 1 "tested merged with main" -- --title "behind" --only unit
grep -q "main broke it" /tmp/local-ci/selftest-toy/*/logs/unit.log 2>/dev/null && ok "and the base branch's new test really ran" || bad "and the base branch's new test really ran"
git checkout -q -b conflicting "$GOOD"; echo "// mine" > test/main.test.js; git add -A; git commit -qm "the same file, differently"
expect "a pull request that conflicts with its base fails at the merge" 1 "conflicts with main" -- --title "conflict"
git checkout -q main; git reset -q --hard "$GOOD"

git checkout -q -b pr-steps "$GOOD"; echo "// change" > change.js; git add -A; git commit -qm "a change"
expect "pull-request steps run for a pull request, with its facts" 0 "ALL CHECKS PASSED" -- --title "My title"
grep -q "title is My title" /tmp/local-ci/selftest-toy/*/logs/title.log 2>/dev/null && ok "the step saw PR_TITLE" || bad "the step saw PR_TITLE"

# The config is data. Nothing in it may become an option to Docker or a command on this machine.
printf 'image --privileged\n' > "$T/evil1"; expect "an image that is really a Docker option is refused"   2 "image takes an image reference" -- --config "$T/evil1"
printf 'image node:24-bookworm\njob a\nstep x: true\nscan gitleaks --no-git\n' > "$T/evil2"; expect "scanner options are refused" 2 "takes no options" -- --config "$T/evil2"
printf 'image node:24-bookworm\ncache ../../etc\n' > "$T/evil3"; expect "a path that climbs out is refused"      2 "cache takes a path" -- --config "$T/evil3"
printf 'frobnicate yes\n' > "$T/evil4"; expect "an unknown word is refused"                                    2 "unknown word" -- --config "$T/evil4"
printf 'image node:24-bookworm\njob a\nstep marker: echo "$(touch /tmp/local-ci-selftest-escaped; echo ran in the container)"\n' > "$T/evil5"
rm -f /tmp/local-ci-selftest-escaped; expect "a config tried out with --config is marked as not the commit's" 0 "not merge evidence" -- --config "$T/evil5" --only marker
[ ! -e /tmp/local-ci-selftest-escaped ] && ok "a step's command ran in the container, not on this machine" || { bad "a step's command ran on this machine"; rm -f /tmp/local-ci-selftest-escaped; }

echo; echo "$PASSED ok, $FAILED wrong"; [ "$FAILED" = 0 ]

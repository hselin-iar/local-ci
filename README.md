# local-ci

Run a project's CI checks on your own machine: one commit, a clean copy of it, Linux containers. It uses no GitHub Actions minutes, and it is built to be as strict as a hosted run, in some ways stricter.

```
local-ci --pr 101        # a pull request as hosted CI sees it
local-ci                 # the commit you are on, as a push is checked
```

Needs Docker and git; `gh` for `--pr`, `--post` and `--watch`; `jq` for the merge hook. Works on macOS, Linux and Windows under WSL 2 (not Git Bash).

## Install

```
git clone <this repository> ~/local-ci
ln -s ~/local-ci/local-ci /usr/local/bin/local-ci     # or add ~/local-ci to your PATH
```

One clone serves every project on the machine. To update, `git pull` in it.

## Set a project up

```
cd my-project
local-ci init            # writes .local-ci/config from a template (node, python, go or generic) and lists the commands in your workflows
$EDITOR .local-ci/config # name the project's real checks
git add .local-ci && git commit -m "local-ci config"
local-ci                 # run them
```

A run always uses the config of the commit it tests, as hosted CI uses the workflow of the commit it tests. To try a config before committing it: `local-ci --config .local-ci/config` (such a run is never merge evidence).

## The config

One instruction per line. It is read as data and never executed on your machine: the commands after `install`, `step` and `x64` run only inside containers, and names, images and paths that could become Docker options are refused.

| Line | Meaning |
|---|---|
| `base <branch>` | The branch pull requests merge into (default `main`). |
| `image <ref>`, `user <name>`, `home <path>` | The image the steps run in, and the unprivileged user they run as. |
| `cache <path>` | A directory in the container kept between runs (a package cache). |
| `keep <path>` | A path in the repository kept between jobs (installed packages). Without it the install runs again for every job. |
| `install <command>` | Runs before the first step. |
| `env NAME=value` | For every step; under a `job`, for that job; under a `service`, for that service. |
| `service <name> <image>` with `health <command>` | A container the steps reach on `127.0.0.1`. Every job that `uses` it gets a fresh one. Make the health command connect the way the steps do: `pg_isready -h 127.0.0.1 ...`, since Postgres's image answers on its unix socket during set-up and then restarts. |
| `job <name>` with `uses <service> ...` | A group of steps on its own fresh checkout, like a CI job. |
| `step <name>: <command>` | A check. |
| `tests node\|tap\|jest\|vitest\|pytest\|go` | Under a step: it must run at least one test; the count is recorded. |
| `count <pattern>` | The same for any other runner: every match in the log adds the last number in it. |
| `expect <pattern>` | Under a step: the log must contain this, or the step fails. |
| `pr-only` | Under a step: runs only for a pull request. It gets `PR_TITLE`, `PR_BRANCH`, `PR_AUTHOR`, `PR_NUMBER`, `BASE_BRANCH`. |
| `x64 <command>` | Run once more as x64 when the machine is arm64. |
| `scan gitleaks`, `scan osv <lockfile> ...`, `scan semgrep <ruleset> ...`, `scan actionlint [options]` | Scanners, each from a pinned image. |
| `mirrors <file> <sha256>` | Fail when that file changes, so the config cannot drift from the workflow it copies. |
| `tool <scanner> <image>` | Pin another version of a scanner. |

Every step also gets `LOCAL_CI_SHA`, `LOCAL_CI_BASE`, `LOCAL_CI_MERGE_BASE`, and the recipes folder at `/local-ci`. See `templates/` and `examples/`.

## Why a pass here means what a pass in hosted CI means

- **The committed files only.** A fresh clone of the commit: no `.env`, no untracked files, no leftovers. Uncommitted changes are not tested, and the run says so.
- **A pull request is tested as its merge.** Hosted CI tests the pull request's head merged into its base. So does this: it fetches the base branch first, merges, and tests the result. A conflict fails the run.
- **A fresh checkout and fresh services per job.** What one job builds or leaves in a database is not there for the next. The scanners read a copy nothing ever writes to.
- **An ordinary user.** Steps run as the unprivileged user you name. Root ignores file permissions.
- **Pinned tools, fresh images.** Scanner versions are fixed; the project image and service images are pulled each run.
- **The pull request's own facts.** With `--pr`, the title, branch, base and author come from GitHub.
- **Secrets.** A pull request is scanned for its own commits, a push for the whole history; a pull request with no commit of its own is scanned in full instead of scanning nothing.

## What it does that hosted CI usually does not

- **No empty pass.** A test step passes only if its log shows tests ran; a scanner only if it shows commits scanned, rules applied, packages read.
- **Test counts.** Each suite's count (for Node's runner, the tests that ran, skipped ones left out) is recorded by tree. When the base branch's count is known and a suite now runs fewer tests, the summary says so in capitals.
- **Drift.** `mirrors` fails the run when the workflow file changes and the config has not followed.
- **x64 on an arm64 machine.** Your install and build repeated on the CPU hosted CI and most servers use.
- **Recipes.** `recipes/drizzle-migrations.sh` checks migrations against a database that already has the base branch's schema: no applied migration edited, none stamped out of order (Drizzle silently skips such a migration on an existing database), every one applied, and nothing left for the generator to write.

## Results

A table at the end; one log per check under `/tmp/local-ci/<project>/<commit>/`; and `summary.md` there, also kept in `.git/local-ci/<commit>.md`, which survives a restart. Paste the summary into the pull request.

`ALL CHECKS PASSED (full run)` is the only result that counts as evidence. `--only`, `--skip` and `--config` runs say they are not, and when they pass they do not replace a full pass already recorded for the same commit (a failure always does).

## Working as a team

- **Sharing a result.** `local-ci --pr <n> --post` puts a `local-ci` status on the head commit and the summary in a comment. The status says what it was measured against (the base branch's tip, the title, the pull request). GitHub records which account posted it. A status uses no Actions minutes.
- **A machine that checks everything.** `local-ci --watch`, on a machine that stays on, checks every open pull request that is not a draft and not from a fork: each new head commit gets a full run and a posted result, one at a time. It runs the pull requests' code in containers on that machine, so use it only where every collaborator is trusted.
- **Whose result counts.** See the hook below.

## The merge hook (Claude Code)

`local-ci hook --install` adds a hook to the repository's `.claude/settings.local.json`. From then on a Claude Code session there cannot run `gh pr merge` unless the pull request's head commit has either:

- every required GitHub check green, or
- a full local-ci run recorded on that machine: no check failed or skipped, made for the pull request as it stands (the same title, branch and author, against the base branch's present tip), with the base branch's own `.local-ci/config`, or
- the same run posted from another machine by a trusted account: the account `gh` is logged in as, plus `git config local-ci.trusted "login1 login2"`. The list lives in that clone's git config, not in a tracked file, so a pull request cannot add its own author.

With `--admin` on the command and no such proof, the hook asks you to approve by hand instead of refusing.

It is strict about the command, so that what it checked is what gets merged: `gh pr merge <number> --squash --match-head-commit <sha>`, the number first, one merge per command (the hook names the sha when it is missing). A merge through `gh api` is refused, and so is anything that looks like a merge when the hook cannot read the command or `jq` is missing.

A pull request that edits `.local-ci/config` is judged by its own edits, so its run is not accepted as proof: the summary records the config's hash, and the hook compares it with the base branch's. For such a pull request (the first one that adds the config included) the way through is `--admin` and your approval, after you have read the change.

## Limits, plainly

- **Evidence can be written by hand.** It is a file in `.git` and a status on GitHub. The hook stops a merge whose run was skipped, forgotten or stale; it cannot stop a session, or a person, set on deceiving it.
- **It is evidence, not a gate.** GitHub's branch protection knows only GitHub's own checks, unless you make `local-ci` a required status. Anyone who can push can post that status, which is why the hook looks at who posted it. Nothing here stops a merge made on GitHub's page.
- **The config travels with the code**, as a workflow file does: a pull request can change its own checks. The merge hook does not accept such a run as proof (see above), but a run by hand still passes, so review changes to `.local-ci/config` as you would changes to a workflow.
- **Containers are not a strong sandbox.** A step is code from the repository running in Docker on your machine. Run only code you would run anyway.
- **The CPU.** On an Apple Silicon Mac the steps run as arm64; only the `x64` command is repeated as x64. `--platform linux/amd64` runs everything as x64 and is several times slower.
- **The image is yours, not a GitHub runner's.** Anything a workflow gets from the runner image or from an action (`setup-node`, a cache, a secret) has to be said in the config as an image, an install command or an env line. Secrets are not supported: checks that need real credentials do not belong here.
- **One run per commit per machine at a time.**

## Checking the tool itself

`tests/hook.sh` runs the merge hook through 48 cases against a stand-in `gh`: what counts as a merge, which pull request is checked, what evidence is accepted, whose shared result counts. `tests/selftest.sh` builds a toy project and proves that a clean commit passes and that each kind of defect fails: a failing test, a test step that runs nothing, a committed token, a pull request behind its base, a conflict, a config that tries to pass options to Docker. Run both after changing `local-ci` or the hook.

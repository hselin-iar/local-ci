#!/usr/bin/env bash
# A recipe for projects that keep Drizzle migrations. CI usually migrates an empty database, which says nothing about the databases that already exist.
# Use it as a step in a job that has its own empty Postgres (every job gets fresh services), for example:
#
#   job migrations
#     uses postgres
#     env DATABASE_URL=postgres://app:app@127.0.0.1:5432/app
#     step migrations: bash /local-ci/drizzle-migrations.sh
#       expect ^migrations ok:
#
# It checks, against that throwaway database and the run's throwaway working copy (nothing else is touched):
#   1. No migration that is already on the base branch was edited, renamed, deleted or reordered, and the journal's timestamps rise in order. Drizzle applies a migration
#      to an existing database only when it is newer than the last one applied there and silently skips an older one, so a migration generated before another one landed
#      would reach a fresh database and never reach the deployed ones.
#   2. A database at the base branch's schema takes this commit's new migrations on top, and afterwards holds every migration in the journal (when the `postgres` or `pg`
#      package is installed to count them).
#   3. The schema files and the migrations agree: the generate command has nothing left to write.
# Settings (environment, all optional): MIGRATIONS_DIR (drizzle), MIGRATE_CMD (npm run --silent db:migrate), GENERATE_CMD (npm run --silent db:generate; set to "-" to skip
# step 3), MIGRATIONS_DATABASE_URL (DATABASE_URL), MIGRATIONS_TABLE (drizzle.__drizzle_migrations). The base commit comes from local-ci as LOCAL_CI_MERGE_BASE.
set -euo pipefail
BASE="${1:-${LOCAL_CI_MERGE_BASE:?run this through local-ci, or pass the base commit}}"
DIR="${MIGRATIONS_DIR:-drizzle}"; MIGRATE="${MIGRATE_CMD:-npm run --silent db:migrate}"; GENERATE="${GENERATE_CMD:-npm run --silent db:generate}"
export MIGRATIONS_DATABASE_URL="${MIGRATIONS_DATABASE_URL:-${DATABASE_URL:-}}" MIGRATIONS_TABLE="${MIGRATIONS_TABLE:-drizzle.__drizzle_migrations}" MIGRATIONS_DIR="$DIR"

echo "== 1. migrations already on the base branch are untouched"
if ! git cat-file -e "$BASE:$DIR/meta/_journal.json" 2>/dev/null; then echo "the base commit has no $DIR/meta/_journal.json: every migration is new"; printf '[]' > /tmp/migration-base-journal
else
  git show "$BASE:$DIR/meta/_journal.json" > /tmp/migration-base-journal
  changed="$(git diff --name-status "$BASE" HEAD -- "$DIR" | grep -E '\.sql$' | grep -vE '^A' || true)"
  if [ -n "$changed" ]; then echo "FAILED: a migration that is already on the base branch was edited, renamed or deleted. Add a new migration instead:"; echo "$changed"; exit 1; fi
fi
node - <<'JS'
const { readFileSync, writeFileSync } = require('node:fs');
const dir = process.env.MIGRATIONS_DIR;
const raw = readFileSync('/tmp/migration-base-journal', 'utf8');
const base = raw === '[]' ? [] : JSON.parse(raw).entries.map((e) => e.tag);
const entries = JSON.parse(readFileSync(`${dir}/meta/_journal.json`, 'utf8')).entries;
const head = entries.map((e) => e.tag);
const at = base.findIndex((t, i) => head[i] !== t);
if (at !== -1) {
  console.error(`FAILED: the journal no longer starts with the base branch's migrations. Position ${at}: the base has ${base[at]}, this commit has ${head[at] ?? 'nothing'}.`);
  console.error('Another migration landed first: rebase, then regenerate yours on top of it.');
  process.exit(1);
}
const late = entries.findIndex((e, i) => i > 0 && e.when <= entries[i - 1].when);
if (late !== -1) {
  console.error(`FAILED: ${entries[late].tag} carries an older timestamp than ${entries[late - 1].tag}, which comes before it in the journal.`);
  console.error('A database that already has the earlier one would skip it without a word. Regenerate it on top of the base branch (rebase first).');
  process.exit(1);
}
writeFileSync('/tmp/migration-base', String(base.length)); writeFileSync('/tmp/migration-head', String(head.length));
writeFileSync('/tmp/migration-counts', `${base.length} on the base, ${head.length - base.length} new`);
console.log(`${base.length} on the base, ${head.length - base.length} new, in order`);
JS

echo "== 2. the base branch's schema, then this commit's migrations on top"
applied() {   # how many migrations the database says it holds; must be the number given
  node - "$1" "$2" <<'JS'
const want = Number(process.argv[2]), when = process.argv[3], url = process.env.MIGRATIONS_DATABASE_URL, table = process.env.MIGRATIONS_TABLE;
const fail = (m) => { console.error(`FAILED: ${m}`); process.exit(1); };
const judge = (n) => { if (n !== want) fail(`after ${when}, the database holds ${n} migrations where the journal lists ${want}. One was skipped or applied twice.`); console.log(`${n} migrations applied after ${when}`); };
if (!/^[A-Za-z0-9_."]+$/.test(table)) fail('MIGRATIONS_TABLE is not a table name');
(async () => {
  let lib = null; for (const name of ['postgres', 'pg']) { try { lib = [name, require(name)]; break; } catch {} }
  if (!lib || !url) { console.log(`not counted after ${when}: needs the postgres or pg package and a database URL`); return; }
  if (lib[0] === 'postgres') { const sql = lib[1](url, { max: 1, onnotice: () => {} }); const rows = await sql.unsafe(`select count(*)::int as n from ${table}`); await sql.end(); judge(rows[0].n); }
  else { const c = new lib[1].Client({ connectionString: url }); await c.connect(); const r = await c.query(`select count(*)::int as n from ${table}`); await c.end(); judge(r.rows[0].n); }
})().catch((e) => fail(`could not read the applied migrations: ${e.message}`));
JS
}
if [ "$(cat /tmp/migration-base)" -gt 0 ]; then
  rm -rf "$DIR" && git checkout -q "$BASE" -- "$DIR"
  $MIGRATE
  applied "$(cat /tmp/migration-base)" "the base branch's migrations"
  rm -rf "$DIR" && git checkout -q HEAD -- "$DIR"
fi
$MIGRATE
applied "$(cat /tmp/migration-head)" "this commit's migrations on top"

if [ "$GENERATE" != "-" ]; then
  echo "== 3. the schema files and the migrations agree"
  $GENERATE </dev/null
  left="$(git status --porcelain -- "$DIR")"
  if [ -n "$left" ]; then echo "FAILED: the schema files describe something the migrations do not create. The generate command wrote:"; echo "$left"; echo "Generate the migration, review it and commit it."; exit 1; fi
fi
echo "migrations ok: $(cat /tmp/migration-counts)"

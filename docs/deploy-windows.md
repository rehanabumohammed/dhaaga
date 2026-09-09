# Deploying to Supabase from Windows (PowerShell)

Everything here runs on your machine. The development environment has no network
route to Supabase and must never hold your database password or service-role
key, so deployment is yours to execute and mine to verify from the output.

Run from the repository root: `C:\flutterproject\dhaaga`

---

## 0 · Prerequisites

```powershell
node --version          # any recent LTS
npm install -g supabase
supabase --version
```

**Optional but worth it:** a Postgres client, which lets you run the full test
suite against the cloud rather than only the SQL-editor checks.

```powershell
winget install PostgreSQL.PostgreSQL.16      # provides psql.exe
python --version                             # 3.10+
```

Without those two, use the **SQL editor path** in step 4 — it covers the same
guarantees, just with less detail.

---

## 1 · Confirm you are pushing what passed

```powershell
Copy-Item .env.example .env        # once, if you have not already
python scripts\migrate.py verify
python scripts\test.py
```

Expect `verify: OK - 17 migrations` and `PASSED 15 files, 434 assertions`.
If either disagrees, stop: the schema on disk is not the schema that was proven.

**There is nothing to `source`.** PowerShell has no such command, and none is
needed: every script reads `.env` from the repository root itself. Save the file
as plain UTF-8 — a byte-order mark and CRLF line endings are both handled.

Each command prints the database it is about to act on before doing anything:

```
  target: 127.0.0.1:5433/dhaaga_dev  [local]
```

Only the host, port and database name appear — never a user or a password — so
the line is safe to paste into a report. **If that line ever reads `[REMOTE]`
when you expected local, stop and check `$env:DHAAGA_DB_URL`.**

If `psql` is missing, the scripts say so and tell you what to install rather
than raising a Python traceback. `migrate.py reset` and `migrate.py down` refuse
outright to run against a database that is not on this machine, which matters in
step 4 Path B below where you deliberately point `DHAAGA_DB_URL` at the cloud.

*(Skip if you do not have Python locally — the same run is reported with each
work package.)*

---

## 2 · Link the project

```powershell
supabase login                                        # opens a browser
supabase link --project-ref rnkazgaixjgdzzaebqyv      # prompts for the DB password
supabase projects list                                # confirm the linked row
```

The password prompt is the CLI's own. **Do not** put the password in a variable,
a script, or this chat — PowerShell keeps command history in
`$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt`.

---

## 3 · Push

```powershell
python scripts\export_supabase.py     # db/migrations -> supabase/migrations
supabase db push
```

You should see 17 migrations applied, ending with `0017_extension_search_path`.

> **If the push stops at 0005 with `operator class "gin_trgm_ops" does not
> exist`**, pg_trgm has landed in the `extensions` schema on this project rather
> than in `public`. Run `alter extension pg_trgm set schema public;` in the SQL
> editor and push again. This is the loud cousin of the pgcrypto problem that
> 0017 fixes; it cannot pass silently because an index cannot be built without
> the operator class.

> **If the push stops partway, do not walk away.** Migrations 0001–0008 create
> the tables; 0009 applies row-level security and 0010 closes the default
> privilege hole. Between 0008 and 0009 every table exists and nothing protects
> it. Fix the reported error and re-run `supabase db push` — it resumes from the
> first unapplied migration. If it cannot be made to succeed promptly, pause the
> project in the dashboard rather than leaving it exposed.

---

## 4 · Verify the cloud database

### Path A — SQL editor (no local tooling)

Open the project → **SQL Editor** → New query. Run each of these whole and
screenshot or copy the result table.

1. Paste the contents of `db\verify\cloud_postcheck.sql` → expect **15 rows, all PASS**.
2. Paste the contents of `db\verify\cloud_isolation.sql` → expect **23 rows, all PASS**.

Both sort FAIL rows to the top, so a failure is the first thing you see. The
isolation check creates and then discards its own fixtures; it leaves nothing
behind.

### Path A1 — prove WP-7 actually works, not merely that it deployed

The two scripts above check structure and isolation. They do not call the PIN
functions, and the PIN functions are the one place where a deployment can be
green while the feature is broken (see ADR-0012 §5 and migration 0017). Run this
too, in the SQL editor, and expect four `t` values:

```sql
-- Creates a person, sets and checks a PIN, then throws it all away.
do $$
declare biz uuid := gen_random_uuid(); usr uuid := gen_random_uuid(); ok boolean;
begin
    insert into business (id, legal_name) values (biz, 'PIN smoke test');
    insert into app_user (id, business_id, full_name) values (usr, biz, 'PIN smoke test');
    perform app.set_pin('4321', usr);
    raise notice 'correct PIN verifies:   %', app.verify_pin(usr, '4321');
    raise notice 'wrong PIN rejected:     %', not app.verify_pin(usr, '9999');
    raise notice 'hash is not the PIN:    %',
        (select pin_hash <> '4321' from user_credential where user_id = usr);
    raise notice 'hash is bcrypt:         %',
        (select pin_hash like '$2a$%' from user_credential where user_id = usr);
    raise exception 'rollback the smoke test';
exception when others then
    if sqlerrm <> 'rollback the smoke test' then raise; end if;
end $$;
```

If `set_pin` raises `function gen_salt(unknown) does not exist`, migration 0017
did not reach this project — check `supabase migration list`.

### Path B — psql (fuller, if you installed it)

Take the connection string from **Project Settings → Database → Connection
string → URI**. It contains the password, so keep it out of history:

```powershell
$env:DHAAGA_DB_URL = Read-Host "Cloud connection string"    # paste, not echoed back into history
psql $env:DHAAGA_DB_URL -f db\verify\cloud_postcheck.sql
psql $env:DHAAGA_DB_URL -f db\verify\cloud_isolation.sql
python scripts\test.py                                      # the full suite, against the cloud
```

Then put the local URL back before doing anything else. `reset` and `down` will
refuse a remote target, but `up` and `seed` will not — they are legitimate
against staging — so the variable must not be left pointing at the cloud:

```powershell
$env:DHAAGA_DB_URL = "postgres://postgres@127.0.0.1:5433/dhaaga_dev"
```

---

## 5 · Load the development seed

This project is development/staging, so the seed belongs in it. It creates
"Dhaaga Tailors (Development)" with placeholder tax codes and five fictional
staff.

**Path A:** SQL editor → paste `db\seed\0001_development_business.sql` → run. It
is idempotent, so running it twice is harmless.

**Path B:** `python scripts\seed.py --verify` with `DHAAGA_DB_URL` set to the
cloud string.

> The production project, when it is created before the P3 pilot, must **not**
> receive this file. `0009_seed_integrity.sql` will fail there, and that is
> correct rather than a defect.

---

## 6 · Backup and restore drill (WP-10)

Do this before the project holds data you would mind losing.

### 6.1 Create a logical backup

The canonical backup mechanism is provider-independent PostgreSQL `pg_dump`.

Back up the cloud development/staging database, not the local `dhaaga_dev` database.

Backup destination:

```text
C:\DhaagaBackups\
```
For unattended operation, PostgreSQL credentials must be supplied through the Windows PostgreSQL password file (`pgpass.conf`) referenced by `PGPASSFILE`. Do not place database passwords in the command line, scripts, source control, or documentation.


Example PowerShell procedure:

```powershell
$backupRoot = 'C:\DhaagaBackups'
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

$env:PGPASSFILE = Join-Path $env:APPDATA 'postgresql\pgpass.conf'

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$backup = Join-Path $backupRoot "dhaaga_backup_${stamp}.sql"

& 'C:\Program Files\PostgreSQL\18\bin\pg_dump.exe' `
    "$env:DHAAGA_DB_URL" `
    --format=plain `
    --file="$backup"

if ($LASTEXITCODE -ne 0) {
    throw "pg_dump failed with exit code $LASTEXITCODE"
}

Get-Item $backup | Select-Object FullName, Length, LastWriteTimeUtc
Get-FileHash $backup -Algorithm SHA256
```

The connection URL used for the cloud database must use the appropriate TLS configuration (for Supabase, `sslmode=require`) and must not contain an embedded password.

The backup file is sensitive business data. Keep it outside the Git repository, restrict access, encrypt it at rest, and apply the project's retention policy.

The original backup artifact is immutable. Record its actual file timestamp, size, and SHA-256 checksum; do not rename an existing backup merely to correct a timestamp.

### 6.2 Restore drill

Backup creation and restoration are separate operations.

A successful `pg_dump` only proves that the database could be serialized. WP-10 is complete only after a backup has been restored into a separate scratch PostgreSQL database and the recovered application data can be queried.

The restore target must be disposable and must not be the production/development database.

The scratch restore procedure must account for provider-managed Supabase objects that do not belong to the application's portable PostgreSQL recovery boundary. Do not create fake Supabase platform roles or infrastructure merely to make a raw provider dump appear restorable.

The recovery drill must verify:

1. the backup can be consumed by the restore procedure;
2. the application schema is restored;
3. application data is restored;
4. representative queries succeed; and
5. recovered row counts can be compared with the source database.

Record the restore result as WP-10 evidence.
```

---

## 7 · Report back

Paste, as text rather than a screenshot if you can:

* the tail of `supabase db push`;
* the 11-row post-check table;
* the 12-row isolation table;
* anything that read FAIL.

I will verify it and, if all of it passes, that is three of the six conditions
for the P0 gate met — migrations applied, cloud isolation, cloud post-check. The
remaining three are the restore drill, the outstanding work packages, and the
P0 definition of done demonstrated end to end.

---

## If something fails

Report the exact output rather than a summary of it, and say whether the push
completed. The three failure shapes and what they mean:

| Symptom | Likely cause | What it means |
|---|---|---|
| `supabase db push` errors on a migration | SQL that the local Postgres accepts and Supabase does not, or an object that already exists in the project | The project is **partially migrated**. Re-run the push after the fix; do not leave it between 0008 and 0009. |
| Post-check fingerprint mismatch | The project holds objects the repository does not know about — a table made by hand in the dashboard, or a partial earlier push | Something was created outside version control. Identify it before proceeding; a schema that exists only in a dashboard cannot be reviewed or rolled back. |
| Isolation check shows any FAIL | Row-level security did not apply, or a policy is missing | **Stop.** The project is reachable with the publishable key. Pause it in the dashboard and report the row that failed. |

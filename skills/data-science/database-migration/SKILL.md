---
name: database-migration
description: "Cross-DBMS migration via Docker CLI tools instead of native drivers — schema extraction, type mapping, data export/import between different database engines using only docker exec + CLI clients inside containers."
version: 1.1.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [database, migration, firebird, mysql, docker, isql, gbak, ETL, schema-migration]
    related_skills: [database-backup-restoration, plan, systematic-debugging]
---

# Database Migration (Driverless Pattern)

## Overview

Migrate data between different database management systems **without installing any native database drivers** on the host. Instead, use `docker exec` to run CLI database tools directly inside existing containers. The pattern works for any source/target pair where both have CLI clients available.

**Core idea:** Instead of "pip install pymysql pyodbc psycopg2 firebird-driver → write Python → DSN strings → driver version incompatibilities", use "docker exec → db_cli → pipe output → parse → pipe input".

## When to Use

- Source or target DBMS lacks a mature Python/Node/Java driver
- You don't want to install DB-specific libraries on the host
- Both DBMS already exist as Docker containers
- The migration is one-off (not a recurring pipeline)
- Source DB does not have a direct dump/restore import path into the target (different engines)

## General Workflow

```
┌──────────┐    ┌─────────────────┐    ┌────────────────┐    ┌──────────┐
│ Source   │───►│ Schema Metadata │───►│ CREATE TABLE   │───►│ Target   │
│ CLI (isql)│    │ (system tables) │    │ generation     │    │ CLI (mysql) │
└──────────┘    └─────────────────┘    └────────────────┘    └──────────┘
      │                                       ▲
      │                                       │
      ▼                                       │
┌──────────┐    ┌─────────────────┐    ┌───────────┐     │
│ Data     │───►│ CSV / pipe      │───►│ Target    │─────┘
│ Export   │    │ transform       │   │ Import    │
└──────────┘    └─────────────────┘    └───────────┘
```

### Step 1: Schema Discovery

Query the source database's system tables to list tables and their column metadata:

- **Firebird:** `RDB$RELATIONS` + `RDB$RELATION_FIELDS` + `RDB$FIELDS`
- **MySQL:** `information_schema.tables` + `information_schema.columns`
- **SQL Server:** `sys.tables` + `sys.columns` + `sys.types`
- **PostgreSQL:** `pg_catalog.pg_tables` + `information_schema.columns`

### Step 2: CREATE TABLE Generation

Map source types to target types in a single dict lookup. Include fallback for unknown types.

**Key design:**
- Always use `CREATE TABLE IF NOT EXISTS` for idempotency
- Set target charset explicitly (e.g. `utf8mb4` for MySQL)
- Skip views, computed columns, and generated columns (they don't hold data)
- Use `LONGBLOB` / `LONGTEXT` for BLOB types (MySQL)

### Step 3: Data Export

Use source CLI in a **machine-parseable output mode**:

| DBMS | CLI Tool | Output Mode | Notes |
|------|----------|-------------|-------|
| Firebird | `isql` | `SET LIST ON` | One column per line, blank line between rows |
| MySQL | `mysql -e "..."` | Tabular (or `--batch --silent`) | Avoid header via `--skip-column-names` |
| SQL Server | `sqlcmd` | `-o` with `-s","` -W | Fixed-width by default; use `-W -s","` for delimited |

### Step 4: Data Import

Use target CLI's bulk-load facility:

| DBMS | Command | Notes |
|------|---------|-------|
| MySQL | `LOAD DATA INFILE` | Check `secure_file_priv` first; fallback to `LOCAL` |
| SQL Server | `bcp` or `BULK INSERT` | Need format file for CSV |
| PostgreSQL | `\copy` (psql) or `COPY` | `\copy` works without superuser |

### Step 5: Verification

Count rows in each target table and compare (at least approximately) with source row counts.

## Shell Quoting Pattern (Critical)

When piping SQL through `docker exec` with `printf`, use **single-quote wrapping with shell-safe escaping**:

```python
def _sq(s):
    """Wrap a string in single quotes for the shell, escaping internal quotes."""
    return "'" + s.replace("'", "'\\''") + "'"

# Usage:
cmd = f"printf '%s\\n' {_sq(sql)} | docker exec -i {container} {cli} {args}"
```

**Important:** Do NOT double-escape — `_sq()` already handles single quotes. Calling an additional `safe_sql()` layer before `_sq()` will produce garbled SQL.

## Type Mapping Strategy

Build a dict keyed by the source system's internal type identifiers. Use a single dict for simple types, plus special-case handlers for types needing parameters (CHAR/VARCHAR length, BLOB subtypes, numeric precision/scale).

```python
FB_TO_MYSQL_TYPE = {
    7:   "SMALLINT",   # SMALLINT
    8:   "INT",        # INTEGER
    12:  "DATE",       # DATE
    14:  "CHAR",       # CHAR (needs length param)
    37:  "VARCHAR",    # VARCHAR (needs length param)
    261: "LONGBLOB",   # BLOB (all sub_types)
}
FB_CHAR_TYPES = {14, 37}
```

## Common Pitfalls

1. **isql multi-page output.** isql repeats headers and separators every ~20 rows. Must filter out ALL `===` lines and `RDB$FIELD_NAME` headers, not just skip the first occurrence.
2. **BLOB display messages.** isql prints `BLOB display set to subtype 1` inline with data. Filter lines starting with "BLOB display".
3. **MySQL secure_file_priv.** Check `SHOW VARIABLES LIKE 'secure_file_priv'` before copying CSV files into the container. Copy to that directory, not arbitrary `/tmp`.
4. **Double single-quote escaping.** Never chain two quote-escaping functions — one is enough. Each layer doubles the shell's interpretation burden.
5. **Forgetting the pipe to docker exec.** `cmd` (the docker exec string) must be part of the final command — piping `printf` output to nowhere silently produces zero output.
6. **Shell timeout on large tables.** For tables with thousands of rows, increase timeout to 300s+ for the export step.
7. **MySQL `--local-infile=1` required.** Without this flag, LOAD DATA LOCAL INFILE fails silently.
8. **PostgreSQL `\connect` in dumps.** Strip `CREATE DATABASE` / `\connect` when importing to existing database — they redirect to wrong database.

## Project-Specific Automated Firebird → SQL Server Pipeline

For the **Conversor/MigBot project**, Firebird → SQL Server migration is fully automated via `migbot/core/formats/firebird_format.py`:

```bash
cd /home/hermes/conversor-backups
PYTHONPATH=. python3 migbot/migbot_bot.py staging/pendentes/cliente/
```

**What it does automatically:**
1. **ODS detection** — reads offset 18 of the `.fdb`/`.gdb` to determine Firebird version
2. **Container selection** — ODS 10 -> fb15, 11 -> fb25, 12 -> fb30, 13 -> fb40
3. **Healthcheck** — waits for Docker health status "healthy" (not just "Running")
4. **Schema + data extraction** — runs dump-dados.sh -> dump_firebird.py -> CSV per table + SQLite
5. **CSV import** — imports all CSVs as NVARCHAR(MAX) tables in SQL Server via restaurar_csv_lote()
6. **Learning registration** — learn_engine records the format, SGBD, and encoding

**Requirements:**
- Docker available via sg docker -c "..."
- docker/firebird-legado/ harness with docker-compose.yml and dump-dados.sh
- Python image python:3.12-slim available (pulled once)
- PYTHONPATH pointing to project root

**Credentials:** SYSDBA / masterkey. Ports: fb25=3050, fb30=3053, fb40=3054, fb50=3055.

This is preferred over the manual CLI migration (isql -> parse -> mysql) for production use. The manual pattern below is best for one-off ad-hoc migrations when the automated pipeline is not available.

## Firebird ODS Version Bridge (gbak)

When a Firebird database's On-Disk Structure (ODS) is too old for your toolchain, use **gbak** as a binary transport layer between two Firebird version containers. This is more reliable than isql text parsing (gbak preserves binary precision for numeric/temporal types) and often the only option when the database engine itself refuses to open the old ODS.

### Problem

Python's `firebirdsql` driver (pure-Python, no `fbclient` needed) connects to Firebird 2.5+ (ODS 11+) but **cannot connect to ODS 10** (Firebird 1.5 / InterBase 6). Attempting `firebirdsql.connect()` to an ODS 10 database gives `connection rejected by remote interface` or `wrong record length` errors. The same applies to any modern tool — FB 2.5+ refuses to open ODS 10 databases.

### Solution: gbak bridge

```
┌──────────────┐    ┌──────────────────┐    ┌──────────────────┐    ┌──────────────┐
│  Original    │───►│ fb15 (FB 1.5)    │───►│ fb25 (FB 2.5)    │───►│ dump-dados.sh│
│  .gdb/.fdb   │    │ gbak -b → .fbk   │    │ gbak -rep → .fdb │──── │ → CSVs       │
│  (ODS 10)    │    └──────────────────┘    └──────────────────┘    └──────────────┘
└──────────────┘
```

1. **Copy** the original `.gdb`/`.fdb` into `data/<job_id>/<job_id>.fdb`
2. **Start fb15** (Firebird 1.5 i386 — the only engine that reads ODS 10)
3. **`gbak -b` inside fb15** — creates a transportable, compressed `.fbk` file (version-independent format)
4. **Stop fb15, start fb25** (Firebird 2.5 — the engine that firebirdsql can connect to)
5. **`gbak -rep -fix_fss_metadata WIN1252` inside fb25** — restores the `.fbk` as an ODS 11+ `.fdb`
6. **Run dump-dados.sh** → exports CSVs + SQLite via Python `firebirdsql` (now connects because ODS 11)

### Key flags

| Flag | When | Why |
|------|------|-----|
| `-rep` (replace) | fb25 restore | `gbak -r` refuses to overwrite an existing file. Since step 1 already placed a `.fdb` there, `-rep` is required. |
| `-fix_fss_metadata WIN1252` | fb25 restore | FB 1.5 stores metadata in charset `FSS` (proprietary single-byte charset). FB 2.5+ rejects this as "Invalid metadata detected. Use -FIX_FSS_METADATA option". `WIN1252` (or `NONE` to skip) fixes it. |
| `-b` (backup) | fb15 backup | Creates a transportable `.fbk` in XDR format (endian-independent, cross-version) |

### Container lifecycle pitfall

**Stale container = stale data.** Docker caches a container's file system at creation time. If you (1) copy a new file into the bind-mounted `data/` directory, then (2) run `docker compose up -d <svc>` while that container already exists, the inode cache may **not** see the new file. The symptom is `gbak: ERROR: I/O error for file "..." — No such file or directory` even though `ls` on the host shows the file.

**Fix — force container recreation before each use:**
```bash
_dc rm -sf svc 2>/dev/null || true   # remove old container, ignore if nonexistent
_up svc                              # create fresh from compose with current data
```

### ODS detection

```bash
_le16() { od -An -tu2 -j "$2" -N 2 "$1" | tr -d ' '; }
ods=$(( $(_le16 "$f" 18) & 0x7fff ))   # mask bit 0x8000 (type flag)
case "$ods" in
    10) echo "fb15" ;;   # IB6/FB1.0/FB1.5
    11) echo "fb25" ;;   # FB 2.0/2.1/2.5
    12) echo "fb30" ;;   # FB 3.0
    13) echo "fb40" ;;   # FB 4.0/5.0
esac
```

Checksum at offset 2 must be `12345` (little-endian 16-bit); if not, it's probably not a valid Firebird database.

### Reference script

`/home/hermes/conversor-backups/scripts/gbak_bridge.sh` implements the full pipeline:

```bash
./gbak_bridge.sh <caminho_fdb_gdb> <job_id>
```

It sources `lib.sh` from the harness (for `_dc`, `_up`, `_fb` helpers), handles container lifecycle, gbak flags, and dump-dados.sh invocation. Echoes the CSV output directory as its final line.

**Credentials:** SYSDBA / masterkey (all firebird-legado containers).
**Ports:** fb25=3050, fb30=3053, fb40=3054, fb50=3055.
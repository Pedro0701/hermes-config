---
name: database-backup-restoration
description: "Use when restoring database backups (any SGBD) into Docker containers — format detection, decompression, SGBD identification, Docker lifecycle, deduplication, SQL-Server-first migration from MySQL/PostgreSQL/Firebird, and Telegram notification of credentials."
version: 1.21.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [database, backup, restore, docker, sql-server, mysql, postgresql, telegram, deduplication]
    related_skills: [plan, systematic-debugging, database-migration]
---

# Database Backup Restoration Pipeline

## Overview

Automates the full lifecycle of receiving a database backup file, identifying its
format (magic bytes, compression, SGBD), restoring it into an isolated Docker
container, and delivering access credentials to the user. Designed for async
operation — restores can take minutes to hours; the user gets progress updates
and a final notification instead of blocking.

## Project: Conversor (MigBot)

The project lives at `/home/hermes/conversor-backups` (repo: `Pedro0701/Conversor`).

**Naming history:** Originally `Sofia`, renamed to `MigBot`. All paths now use
`migbot/` — the old `sofia/` directory was removed. Key entry point:
- `migbot/migbot_bot.py` (was `sofia/sofia_bot.py`)
- `migbot/core/config.py` (was `sofia/core/config.py`)
- `scripts/migbot_kanban_watchdog.sh` (was `sofia_kanban_watchdog.sh`)

**Google Drive path:** Backups are at `gdrive:1.Profissional/Conversor/Backup/`,
exports go to `gdrive:1.Profissional/Conversor/Exportacao/`,
completed restores go to `gdrive:1.Profissional/Conversor/Resultado/`.
(Not `Conversosr` with typo — the real folder name is `Conversor`.)

## When to Use

- User sends/uploaded a database backup file (.bak, .sql, .csv, .dump, .bacpac)
- User asks to restore a backup from cloud storage (Google Drive, OneDrive, etc.)
- User asks to restore a backup into a Docker container
- You need to detect compressed/archived backup formats (.zip, .gz, .tar.gz, .rar, .7z)
- You need to identify which SGBD produced a .sql dump (MySQL vs SQL Server vs PostgreSQL)
- You need to notify the user (Telegram) when a long restore finishes

## Workflow Style (User Preference)

This user:
- **MCP é a ÚNICA via de restauração.** Nunca executar `migbot_bot.py` diretamente no host. Toda restauração deve ser feita via MCP tools (`restore_backup`, `list_backups_on_drive`, etc.) que rodam dentro do container `migbot_mcp`. O worker do kanban carrega as skills mas restaura via MCP, não via bot direto.
- **Prefers kanban-based async workers** for restores (token-efficient: ~30-50K tokens per worker vs 330K+ in main chat). Detection is `no_agent=true` (0 tokens).
- **Wants you to ask before wiring new modules end-to-end into the pipeline.** If you're building a new feature (like a learn_engine), present the plan first and get a green light before integrating. "Cancela o ajuste" means stop and revert to the prior safe state — do NOT continue integrating after a cancel signal.
- **Wants commits in Portuguese** with emoji prefixes (`✨`, `🐛`, `♻️`, `📝`, `🔒`).
- **Wants only tables restored** — no views, functions, procedures, or triggers. This is enforced by `_filtrar_sql_tabelas()` / `_filtrar_tsql_tabelas()` / `_filtrar_pgsql_tabelas()` and by `_limpar_objetos_nao_tabela_sqlserver()` for `.bak` files. Do not remove this filter or add an opt-out flag — it is the project's invariant.
- **Communicate in Portuguese (Brazilian).** All responses, commit messages, and documentation should be in Portuguese.
- **Prefers delegation for long tasks.** Installations, downloads >100MB, multi-step builds, and restores expected to take >5 minutes should be delegated to subagents or run in background with `notify_on_complete=true`.
- **Values token efficiency.** Prefer `no_agent=true` watchdogs (0 tokens idle), kanban triggers, and background workers (~30-50K tokens) over running restore flows directly in the main conversation (~330K+ tokens).

## Cloud Storage as Backup Source

When backup files live in cloud storage, use **rclone**. It supports 40+ providers
and does not require a GCP project. Setup:

```bash
curl -sL -o /tmp/rclone.zip \
  "https://github.com/rclone/rclone/releases/download/v1.69.2/rclone-v1.69.2-linux-amd64.zip"
unzip -q /tmp/rclone.zip -d /tmp/rclone_extract
mkdir -p ~/bin && cp /tmp/rclone_extract/rclone-*/rclone ~/bin/ && chmod +x ~/bin/rclone
export PATH="$HOME/bin:$PATH"
rclone authorize "drive"
```

### Common rclone commands

```bash
# List top-level backup folders (AVOID --format "stp" — see pitfall #37)
rclone lsf "gdrive:1.Profissional/Conversor/Backup/" --format "sp" --separator "|"
rclone copy "gdrive:1.Profissional/Conversor/Backup/[sistema]cliente" ./staging/pendentes/cliente/ --progress
rclone mkdir "gdrive:1.Profissional/Conversor/Resultado"
rclone move src dst --progress
```

**Timeout:** rclone copy defaults to 300s. Use 3600s for files >100MB.
**Data freshness:** Skip files with ModTime < 10min ago to avoid partial uploads.

### Watchdog / Auto-Restore Pattern (cron + kanban)

Two approaches exist; prefer **kanban** for token efficiency. The dispatcher is
now **embedded in the gateway** (`hermes gateway start`). The standalone
`hermes kanban daemon` command is deprecated and will refuse to start unless
`--force` is passed.

#### Kanban (preferred — zero-token detection)

```
Cloud Folder (Backup/) →┬─ migbot_kanban_watchdog.sh (cron 15min, no_agent=true, 0 tokens)
                         │   1. rclone lsf → list files in Backup/
                         │   2. python3 sqlite3 → filter already-processed (dedup registry)
                         │   3. For each new backup → hermes kanban create (with --skill flags)
                         │
                         └─ Kanban Board (dispatcher in gateway, ticks every 60s)
                              ├─ Task ready → assigned → running
                              └─ Worker agent (isolated session, ~30-50K tokens)
                                   ├─ Loads skills: migbot-cloud-restore-export + database-backup-restoration
                                   ├─ Downloads → restores → exports → uploads
                                   └─ kanban_complete()
```

```bash
# Setup
cp /home/hermes/conversor-backups/scripts/migbot_kanban_watchdog.sh \
  ~/.hermes/scripts/migbot_kanban_watchdog.sh
cronjob action=create schedule="every 15m" name="MigBot Watchdog" \
  script=migbot_kanban_watchdog.sh no_agent=true deliver=telegram

# Manual task creation
hermes kanban create "Restaurar [sistema]cliente" \
  --body "Descrição com passos..." \
  --skill migbot-cloud-restore-export \
  --skill database-backup-restoration \
  --assignee default \
  --priority 1 \
  --max-runtime 2h

hermes kanban assign <task_id> default
hermes kanban dispatch  # força ciclo imediato
```

**Critical: `--assignee default` is required** — dispatcher ignores unassigned tasks.

**CRITICAL: Watchdog sync.** The cron runs the script from `~/.hermes/scripts/`.
After every change to `scripts/migbot_kanban_watchdog.sh`, you MUST copy it back:
```bash
cp /home/hermes/conversor-backups/scripts/migbot_kanban_watchdog.sh \
  ~/.hermes/scripts/migbot_kanban_watchdog.sh
```
The cron copy can diverge silently — paths (Drive, PROJETO, DB, staging) become
stale and the watchdog exits silently with no effect.

#### Direct Watchdog (alternative, lock-based)

```
Cloud Folder (Backup/) →┬─ watchdog (cron every 15m)
                         │   1. List files in Backup/
                         │   2. Filter out already-processed
                         │   3. Acquire lock (file-based, TTL=2h)
                         │   4. Download first pending → Migbot restore
                         │   5. Move to Resultado/ with status prefix
                         └─ (lock prevents concurrent restores)
```

Lock file: `/tmp/.migbot_watchdog.lock` with 2h TTL.

**Notification timing:** Send Telegram BEFORE download, not after — user needs immediate feedback.

### config.py auto-load .env

Python's `os.getenv()` does not read `.env` automatically. The `config.py` already
includes a `_carregar_env()` function at import time. When running outside docker-compose
(cron, CLI), all `os.getenv()` calls work because of this.

## Architecture Pattern

```
 Cloud ─► rclone ─► staging/ ─► Format Detection ─► Decompress ─► Dedup Check ─► Docker Restore ─► Notify
                    │               │                  │               │               │
                    ▼               ▼                  ▼               ▼               ▼
              backup files     magic bytes +         .zip → .sql    SHA-256 hash    SQL Server /
                               extension              .gz → .sql     ↔ SQLite DB     MySQL /
                                                        .tar.gz → ...                PostgreSQL
```

## Format Detection Strategy

### 1. Magic bytes (never trust extension alone)

| Magic bytes | Format | Priority |
|-------------|--------|----------|
| `\x1f\x8b\x08` | GZIP | High |
| `\x50\x4b\x03\x04` | ZIP | High |
| `\x52\x61\x72\x21\x1a\x07` | RAR | High |
| `\x37\x7a\xbc\xaf\x27\x1c` | 7z | High |
| `\x42\x5a\x68` | BZIP2 | High |
| `\xfd37zxa\x00` | XZ | High |

.bak (SQL Server) has no universal magic — trust the extension but validate
via `RESTORE HEADERONLY`/`FILELISTONLY`.

Firebird/InterBase databases (.fdb/.gdb/.fbk) have no magic bytes either, but can
be identified by a **fixed checksum (12345)** at byte offset 2 (little-endian 16-bit).
The ODS number at offset 18 determines which container to use: ODS 10→fb15, 11→fb25,
12→fb30, 13→fb40. Credentials: `SYSDBA`/`masterkey`.

### 2. Compression layer detection

When detected, extract to a temp dir and re-run detection on extracted files.
Support recursive extraction (nested archives).

### 3. SQL SGBD detection from content

For .sql files, score the first 500-5000 chars against known markers.
Pick the highest total. If scores tie or all are 0, ask the user.

### 4. Unknown formats

When confidence < 0.5, notify the user with evidence and ask which SGBD
generated the backup. Do NOT proceed with a blind restore.

## Restoration Strategy per Format

| Detected Format | Primary SGBD (Docker) | Fallback | Notes |
|---|---|---|---|
| .bak | SQL Server | / | Use `RESTORE FILELISTONLY` + `MOVE` clauses |
| .sql (T-SQL) | SQL Server | / | Use `sqlcmd -i` or batch by `GO` |
| .sql (MySQL) | MySQL | SQL Server | Use pipe: `mysql < file` (NOT `SOURCE` via `-e`!) |
| .sql (PostgreSQL) | PostgreSQL | / | Use `psql -f` |
| .csv | SQL Server (try first) | MySQL (fallback) | `pandas` + `sqlalchemy` + `pymysql` |
| .bacpac | SQL Server | / | Via `SqlPackage` CLI (not yet supported) |
| .gdb / .fdb | Firebird (ODS → container → CSV → SQL Server) | / | Detect ODS (10=fb15, 11=fb25, 12=fb30, 13=fb40), extract to CSV via `dump_firebird.py`, import as CSV_LOTE into SQL Server |
| Compressed | Extract → redetect | / | Recurse to non-compressed format |

## All-Backups-to-SQL-Server Migration

Since October 2026, **every backup format ultimately lands in SQL Server**.
MySQL and PostgreSQL dumps are no longer left in their native container — they
are automatically migrated after import:

### How it works

1. The dump is imported into its native container (MySQL or PostgreSQL), as before
2. After success, the migration method reads all tables via pandas/SQLAlchemy
3. Each table is recreated as `NVARCHAR(MAX)` in the **SQL Server** container
   via `_shared.migrar_tabelas_para_sqlserver()`
4. If migration fails, **the original result is preserved** — data is never lost
5. The `learn_engine` registers the conversion as a known fallback path

### Implementation

| Method | Source | Strategy |
|--------|--------|----------|
| `_migrar_mysql_para_sqlserver()` | MySQL container | Uses `pandas.read_sql` to pull each full table, feeds to `migrar_tabelas_para_sqlserver()` |
| `_migrar_postgres_para_sqlserver()` | PG container | Uses `psycopg2` server-side cursor with name — 5K-line paginated, never loads full table in RAM |

Both are called from their respective `restaurar_sql_*()` methods. When migration
succeeds, the result shows `sgbd="sqlserver"` with `fallback_ocorreu=True` and a
`motivo_fallback` describing the conversion.

### Result matrix

| Source format | Intermediate container | Final destination |
|---|---|---|
| `.bak` (SQL Server) | None (native) | SQL Server ✅ |
| `.sql` T-SQL | None (native) | SQL Server ✅ |
| `.sql` MySQL | MySQL (ephemeral) | **SQL Server** 🆕 |
| `.sql` PostgreSQL | PG container | **SQL Server** 🆕 |
| CSV / CSV_LOTE | None | SQL Server ✅ |
| TXT | None | SQL Server ✅ |
| `.fdb/.gdb` (Firebird) | FB container → CSV | SQL Server ✅ |
| pg_dump -F d | PG ephemeral | SQL Server ✅ |

### Priority rule for .bak

Always try SQL Server `RESTORE DATABASE` first. Only fallback to another SGBD
if the RESTORE fails definitively (version incompatibility, corruption).

## Docker Container Lifecycle

### Compose file

The project's Docker infrastructure lives at `infra/docker-compose.yml` (not the
repo root — it was moved from the root `docker-compose.yml` during the `infra/`
reorganization). All `docker compose` commands must use `-f infra/docker-compose.yml`.

```bash
cd /home/hermes/conversor-backups
cp infra/.env.example infra/.env
sg docker -c "docker compose -f infra/docker-compose.yml up -d"
```

### Fixed containers

| Container | SGBD | Port | Healthcheck |
|-----------|------|------|-------------|
| `sqlserver_migrados` | SQL Server 2022 Developer | 1433 | `sqlcmd -C -Q 'SELECT 1'` (40s start, 10s interval) |
| `mysql_migrados` | MySQL 8.0 | 3307 | `mysqladmin ping` (30s start, 10s interval) |
| `postgres_migrados` | PostgreSQL 15 Alpine | 5432 | `pg_isready` (5s interval) |

All three have `restart: unless-stopped` and service-level `depends_on` with
`condition: service_healthy`, so the `migbot-mcp` container only starts after
all databases are ready.

### Healthcheck pattern
```python
def garantir_sqlserver():
    1. Check `docker version` → abort if unavailable
    2. Check `docker inspect -f '{{.State.Running}}' sqlserver_migrados
    3. If not running: `docker compose -f infra/docker-compose.yml up -d sqlserver`
    4. Poll health via docker inspect `'.State.Health.Status'` every 5s for up to 120s
    5. Test TCP port (1433/3307/5432) via socket.create_connection
```

### File transfer into container
Use `docker cp` for small files. For large files (>1GB), pipe via stdin:
```bash
docker exec -i container sh -c 'cat > /path' < local_file
```

For compressed dumps, pipe directly into database CLI:
```bash
gunzip -c dump.sql.gz | docker exec -i mysql_migrados mysql -uroot -p'PASS' db
```

### Credentials pattern
Use **fixed credentials** per SGBD (read from `.env`): `sa`/`Sofia@2024!` for
SQL Server, `root`/`Sofia@2024!` for MySQL.

## Deduplication

SHA-256 of binary content (not filename) as the dedup key. Store in SQLite
at `sistemas_migrados/registro_backups.db`.

### Reset stuck registrations
When a restore fails mid-way, the dedup registry stays `EM_ANDAMENTO`:
```python
from registro_backups import RegistroBackups
reg = RegistroBackups()
for r in reg.listar():
    if r['status'] == 'EM_ANDAMENTO':
        reg.resetar(r['hash_arquivo'][:12])
```

## Continuous Learning (Learn Engine)

The project includes a continuous learning system at `migbot/core/learn_engine.py`
that persists knowledge across workers in a SQLite database (`conhecimento_backups.db`):

| What it learns | How it helps next worker |
|---|---|
| Format of known filenames | Skips re-detection for archives with known internals |
| SGBD preference per client+format | Tries the right SGBD first instead of default order |
| Encoding + delimiter per client | Prioritizes encodings that worked before for CSV imports |
| Error patterns + solutions | Detects recurring errors and applies known fixes |
| Successful fallback paths | Learns "if X fails, try Y" patterns |

**Flow:** each `MigbotBot.processar_arquivo()` call consults `BancoConhecimento`
before detection (Etapa 0.5) and registers learning after conclusion (Etapa 6).
The `restore_engine.py` also queries and registers encoding preferences per client
during CSV imports. All learning is best-effort — never invalidates the restore.

**Thread-safety:** The knowledge base uses SQLite WAL mode, safe for concurrent
readers. Writers serialize naturally (one restore at a time in the current setup).
For fully parallel workers, consider sharding by client name or switching to
PostgreSQL.

## MCP Server — Two Variants

The project has **two** MCP server implementations for different deployment contexts:

### Variant A — Stdio FastMCP (direct Hermes integration)

**File:** `mcp_server.py` (repo root) — FastMCP, stdio transport, 6 tools.

| Tool | Function |
|------|----------|
| `restore_backup(path, sgbd_manual, senha)` | Executes full restoration pipeline |
| `list_backups_status()` | Lists all processed backups with status |
| `reset_backup(hash_ou_prefixo)` | Removes dedup entry for reprocessing |
| `learn_report()` | Shows learn_engine statistics |
| `list_backups_on_drive()` | Lists pending backups on Google Drive |
| `move_to_resultado(nome, prefixo)` | Moves completed backup to Resultado/ |

**Setup in Hermes:**
```bash
hermes mcp add migbot --command "python3" --args "/home/hermes/conversor-backups/mcp_server.py"
```

Requires `fastmcp` (pip-installed). Runs on stdio transport — started by Hermes
on demand. No daemon needed.

### Variant B — HTTP FastAPI + MCP (container deployment)

**File:** `migbot/mcp_server.py` — FastAPI + `fastapi-mcp`, runs via uvicorn, 13 tools.

Exposed as a container service (`migbot-mcp`) in `infra/docker-compose.yml` with
`network_mode: host` (Linux), port 8901. Access via `http://localhost:8901/mcp`.

The same FastAPI routes are exposed both as REST endpoints and auto-mounted MCP
tools (via `fastapi-mcp`'s `mount_http`):

| Category | REST endpoint | Tool |
|----------|--------------|------|
| **consulta** | `GET /health` | health |
| | `GET /sistemas` | listar_sistemas |
| | `GET /sistemas/identificar?nome_arquivo=` | identificar_sistema |
| | `GET /backups?nome=&limite=` | verificar_backup |
| | `GET /backups/recentes?limite=` | listar_backups |
| | `GET /jobs/{job_id}` | status_job |
| | `GET /jobs?limite=` | listar_jobs |
| | `GET /conhecimento?nome_arquivo=` | consultar_conhecimento |
| **ação** | `POST /restore` | restore_backup |
| | `POST /backups/reset` | reset_backup |
| | `GET /aprendizado/relatorio` | learn_report |
| | `GET /drive/backups` | list_backups_on_drive |
| | `POST /drive/mover` | move_to_resultado |

The `restore_backup` endpoint uses a file-based lock (`MIGBOT_MCP_INCOMING`)
serialized via `_LOCK_DIR` with 2h TTL — concurrent restores return `OCUPADO`.

**Container deployment:**
```bash
cd /home/hermes/conversor-backups
cp infra/.env.example infra/.env   # preencha SA_PASSWORD, MYSQL_ROOT_PASSWORD
sg docker -c "docker compose -f infra/docker-compose.yml up -d"
```

Dockerfile at `infra/migbot-mcp/Dockerfile` — slim Python 3.13 image with ODBC,
rclone, unrar, p7zip, and the Docker CLI (socket-mounted for `restore_backup`).

**Why two variants:** The stdio server (Variant A) is simpler for direct Hermes
integration. The HTTP server (Variant B) is designed for long-running deployments
alongside the database containers — it can survive restarts, be healthchecked,
and serve multiple MCP clients.

## Telegram Notification

Use the Bot API via HTTP POST:

```
POST https://api.telegram.org/bot{TOKEN}/sendMessage
{"chat_id": "...", "text": "...", "parse_mode": "HTML"}
```

### Message templates

**Restore started (watchdog — sent before download):**
```
🔄 Nova restauração iniciada!
📦 Arquivo: <nome_arquivo>
📏 Tamanho: <size>MB

Baixando do Google Drive e preparando ambiente...
```

**Success (includes credentials):**
```
✅ Restauração concluída!
📦 Arquivo: <nome>
🗄️ SGBD: <SGBD>
🌐 Host: <host>:<porta>
🗂️ Banco: <nome_banco>
👤 Usuário: <user>
🔑 Senha: <pass>
⏱️ Tempo: <duração>
```

**Failure:**
```
❌ Restauração falhou
📦 Arquivo: <nome>
📋 Motivo: <mensagem>
```

## Failure Recovery Plan

| Failure | Symptom | Action |
|---------|---------|--------|
| Container stopped | "Container X not available" | `docker start <container>` → reset dedup → re-run |
| Password needed | AGUARDANDO_SENHA | Find `senha_bkp.txt` in Drive → re-run with `--senha` |
| Format unknown | AGUARDANDO_INFO | Re-run with `--sgbd sqlserver\|mysql\|postgresql` |
| Partial import (CSVs) | "partially imported with N tables" | Import missing CSV manually or drop+reimport |
| Stuck EM_ANDAMENTO | Job died mid-way | Reset dedup entry → re-run |
| Dedup says CONCLUIDO but DB gone | Credentials fail | Verify DB exists, if gone reset dedup and re-import |
| Export skipped | Job CONCLUIDO but no CSVs | Run export manually via `export_engine` CLI |

## Common Pitfalls

1. **Extension lying.** A `.bak` may be a renamed tar/zip. Always check magic bytes first.
2. **Compression nesting.** Recurse until hitting a non-compressed format.
3. **SQL Server .bak path issues.** RESTORE runs inside container — paths must be container-visible.
4. **GO separator confusion.** SQL Server dumps use `GO` as batch separator.
5. **MySQL `SOURCE` via `-e` gives false negative.** Use pipe: `mysql < file`.
6. **Database name from staging dir gets job_id.** Pass `nome_banco_override` when source is a directory.
7. **Docker cp timeout on >1GB files.** Use pipe instead.
8. **PostgreSQL `\connect` redirects import to wrong database.** Strip `CREATE DATABASE`/`\connect`.
9. **Table-only filter expands file 10x.** Plan disk space for compressed + extracted + filtered.
10. **Password file must be named `senha.txt` and content must be raw password or `chave: valor`.**
    Migbot's `_ler_senha()` in `format_detector.py` accepts only (a) a raw password on a single line, or
    (b) a `chave: valor` / `chave=valor` pattern with keys `senha`/`password`/`pwd` (case-insensitive).
    A file with `1|ddqdawixmw` (pipe-separated `id|password`) is NOT recognized — it treats `1|ddqdawixmw`
    as the literal password, causing extraction failure. Strip any prefix before writing the file.
11. **Compressed archive with only CSVs needs redetect as CSV_LOTE.** Delete original archive from staging first.
12. **`[sistema]` prefix lost in rclone copy.** Create subfolder with bracket name before copying.
13. **Kanban task without `--assignee default` stays ready forever.**
14. **Docker group not active.** Use `sg docker -c "command"`.
15. **rclone cat unreliable for small files.** Use `rclone copy` to temp then `cat`.
16. **rclone auth port collision.** Port 53682 may be in use. Kill stale process.
17. **Firebird .fdb/.gdb inside .zip fails with "Formato composto não pôde ser identificado".**
    The format detector correctly identifies the inner file as Firebird (ODS checksum=12345 → sgbd="firebird"),
    but `restore_engine.py`'s `restaurar()` method in the `COMPOSTO` elif chain (line ~1230) only has handlers
    for `sqlserver`, `mysql`, and `postgresql` — `firebird` falls through to the `else:` branch which returns
    "Formato composto não pôde ser identificado após extração."
    **Fix:** Add `elif formato.sgbd == "firebird":` before the `else:` clause, searching `staging_path.rglob()`
    for `.fdb`/`.gdb`/`.FDB`/`.GDB` (case-insensitive on Linux) and delegating to `self.restaurar_firebird()`.
18. **Firebird container healthcheck — wait for "healthy" not "Running".**
    The `.State.Running` check returns `true` before the Firebird engine accepts connections.
    Wait for `.State.Health.Status == "healthy"` (5s interval, up to 120s). Also handle `"unhealthy"`
    as immediate failure without retry.
19. **dump_firebird.py sqlite3 adapters for Python 3.12.**
    Python 3.12 dropped default sqlite3 adapters for `datetime.date`, `datetime.datetime`,
    `datetime.time`, `datetime.timedelta`, and `Decimal`. Register custom adapters
    (`isoformat()` for dates, `str()` for Decimal and time types) at import time.
    Without these, `sq.executemany(ins, batch)` throws `ProgrammingError: type not supported`.
20. **Compressed archive extracted path points to deleted temp_dir.** When a
    `.zip`/`.rar` contains an inner `.fdb`/`.gdb`, `formato.arquivos_internos` points to the
    extracted temp dir that gets cleaned up. The `COMPOSTO` handler must search the
    **staging dir** for the Firebird file (via `staging_path.rglob("*.fdb") / rglob("*.GDB")`),
    not use the temp paths.
21. **Firebird `.GDB` extension is uppercase — case-insensitive matching required.**
    `pathlib.rglob("*.gdb")` does NOT match `FILE.GDB` on Linux. Add explicit patterns
    for both cases (`.fdb`, `.FDB`, `.gdb`, `.GDB`) or use `str.lower().endswith()`.
    Same for `os.listdir` filters in `migbot_bot.py`.
22. **`_PROJETO` path depth — count parents from `formats/` dir.** In `firebird_format.py`
    (lives at `migbot/core/formats/`), reaching the repo root requires
    `Path(__file__).resolve().parent.parent.parent.parent` (4 levels: formats → core → migbot →
    conversor-backups). A 3-parent chain resolves to `migbot/`, and docker data dir gets created
    in the wrong place with "FileNotFoundError" on the dump script.
23. **`docker/firebird-legado/data/` becomes root-owned after container runs.**
    The Firebird containers write to the bind-mounted `data/` as root, so the local user
    loses write access and `mkdir` fails with `PermissionError: [Errno 13]`.
    Fix without sudo: run an alpine chown container once:
    ```bash
    sg docker -c "docker run --rm -v $PWD/docker/firebird-legado/data:/data alpine chown -R 1000:1000 /data"
    ```
    This is an environment fix, not a code change — re-run when the error reappears after
    a fresh `docker compose pull`.
24. **Never trust the extracted file path in `formato.arquivos_internos` for restores; always
    re-locate the file inside staging.** The temp extraction dir is deleted after detection
    (pitfall 6 above) but callers still receive stale absolute paths. The safe pattern is to
    scan the staging directory for the final candidate (`.sql`, `.bak`, `.fdb`, `.gdb`) and use
    that path for the restore.
25. **`restaurar_csv_lote()` stops on first CSV failure — subsequent CSVs skipped.**
    Each `to_sql` auto-commits with `if_exists="replace"`, so CSVs before the failing one
    are committed. The failing CSV and all after it are NOT imported. If you re-run after
    fixing the CSV, rename/prepare the staging to contain only the missing files, or use
    `restaurar_csv()` singly.
26. **CSV encoding fallback can still fail on semicolon-delimited files.**
    `pandas.read_csv(sep=None, engine="python")` auto-detects `,` and `\t` but NOT `;`.
    If a Brazilian system uses `;` as delimiter (common in CP1252 exports), the auto-detect
    yields a single wide column, which pandas happily consumes. The symptom is a table with
    1 column instead of N. Detect this by checking `len(df.columns)` after read — if it's 1
    and should be N, try `sep=";"`.
27. **Runtime SQLite databases and job files forgotten in .gitignore.** 
    The project produces several runtime artifacts that must NOT be versioned:
    `migbot/conhecimento_backups.db` (learn engine), `sistemas_migrados/registro_backups.db`
    (dedup), `migbot/jobs/*.json` (job state), and `*.db` anywhere. Missing these in
    `.gitignore` causes dirty commits, merge conflicts, and repo bloat. Verify with a
    script: create a temp git init, copy `.gitignore`, touch each artifact path, run
    `git status --porcelain` — tracked means the pattern is missing.

28. **`sg docker -c` fails inside containers (root user, no `docker` group).**
    When `firebird_format.py` (or any restore code) runs inside a container like `migbot_mcp`,
    the `sg docker -c` prefix fails with `sg: no such group` because the container runs as root
    and has no `docker` group (the Docker socket is bind-mounted directly).
    **Fix:** Use `os.geteuid() == 0` to detect container context and dispatch accordingly:
    ```python
    inside = os.geteuid() == 0
    if inside:
        subprocess.run(["docker", "inspect", ...], ...)
    else:
        subprocess.run(["sg", "docker", "-c", "docker inspect ..."], ...)
    ```
    This applies to all Docker subprocess calls in `firebird_format.py` (`_subir_servico`,
    `_executar_dump_dados`, `_derrubar_servico`).

29. **`docker compose` CLI plugin not available inside container.**
    The `docker:27-cli` image only provides the `docker` binary — it does NOT include the
    `docker compose` plugin. Running `docker compose ...` inside the container fails with
    `unknown shorthand flag: 'f' in -f` (docker interprets `compose` as an argument name).
    **Fix:** Install the plugin at container runtime:
    ```bash
    DOCKER_CONFIG=/usr/local/lib/docker/cli-plugins
    mkdir -p $DOCKER_CONFIG
    curl -sL "https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-$(uname -m)" \
      -o $DOCKER_CONFIG/docker-compose
    chmod +x $DOCKER_CONFIG/docker-compose
    ```
    Or add this `RUN` to the Dockerfile.

30. **Bind-mount paths resolve on the host, not inside the container.**
    When running `docker run` or `docker compose` from within a container (`migbot_mcp`),
    the Docker daemon resolves bind-mount source paths on the **host** filesystem, not inside
    the calling container. A path like `/app/infra/firebird-legado/data` is a valid container
    path but does NOT exist on the host — the daemon creates an empty directory instead.
    **Fix — `REPO_HOST_PATH` pattern:** Pass the host-visible repo path as an environment
    variable to the container, then use dual-path variables:
    ```bash
    # In docker-compose.yml:
    environment:
      REPO_HOST_PATH: "/home/hermes/conversor-backups"
    
    # In lib.sh — two path variables:
    HARNESS_DIR_HOST="${HARNESS_DIR}"        # for Docker volume mounts (host-visible)
    if [ -n "${REPO_HOST_PATH:-}" ]; then
      HARNESS_DIR_HOST="${HARNESS_DIR/#\/app/$REPO_HOST_PATH}"
    fi
    # DATA_DIR_HOST similarly
    ```
    All Docker `-v` and volume mount flags must use `HARNESS_DIR_HOST`, while local file
    existence checks (`_rel()`) use `HARNESS_DIR`/`DATA_DIR`.

32. **`detectar_formato_pasta()` does not propagate `sgbd_manual` for CSV_LOTE.**
    When a backup is a `.zip` containing only CSVs, `detectar_formato_pasta()` was called
    without the `sgbd_manual` parameter, so `resultado.sgbd` was always `""` and
    `restaurar_csv_lote` defaulted to SQL Server but the redetection returned DESCONHECIDO.
    **Fix (format_detector.py):** Add `sgbd_manual: Optional[str] = None` parameter to
    `detectar_formato_pasta()`, set `resultado.sgbd = sgbd_manual or ""` in the CSV_LOTE branch.
    **Fix (migbot_bot.py):** Pass `sgbd_manual=sgbd_manual` to the call.
    **Fix (restore_engine.py):** Use `formato.sgbd or "sqlserver"` as `sgbd_destino` for CSV_LOTE.

33. **ZIP removal path wrong when backup is a folder.**
    When `eh_pasta=True`, `arquivo_staging` points to a subdirectory inside `staging_dir`
    (e.g. `staging/<job_id>/dump_SSEscola_fb25/`), but the old code tried to remove the ZIP
    from `staging_dir` directly (the parent), not from the subdirectory. The ZIP stayed,
    `detectar_formato_pasta()` saw a mix of `.csv` + `.zip`, and rejected it as DESCONHECIDO.
    **Fix (migbot_bot.py):** Use `Path(arquivo_staging)` as the target for ZIP removal, not
    `staging_dir`.

34. **CSVs extracted from zip inside a folder backup go to the wrong location.**
    When `eh_pasta=True`, the original code copied extracted CSVs to `staging_dir` (flat),
    but the zip lived inside a subdirectory (`staging/<job_id>/<nome>/`). After removing the
    zip from the subdirectory, the CSVs weren't there — they were in the parent.
    **Fix (migbot_bot.py):** Compute `pasta_destino = Path(arquivo_staging) if eh_pasta else staging_dir`
    and copy extracted files to `pasta_destino`.

35. **CSV_LOTE redetection via `detectar_formato_pasta()` is fragile.**
    Even with the path fixes above, `detectar_formato_pasta()` kept returning DESCONHECIDO
    for a directory of pure `.csv` files. Unknown edge case (possibly permissions, inode
    caching, or subdirectory remnants). Instead of debugging further, skip redetection entirely
    when the format is already known as `COMPOSTO` → `CSV`:
    ```python
    novo_formato = ResultadoDeteccao()
    novo_formato.formato_primario = FormatoBackup.CSV_LOTE
    novo_formato.arquivos_internos = [
        str(pasta_com_zip / Path(f).name) for f in formato.arquivos_internos
    ]
    novo_formato.sgbd = sgbd_manual or "sqlserver"
    novo_formato.confidence = 0.9
    formato = novo_formato
    eh_pasta = True
    ```
    This bypasses the fragile `detectar_formato_pasta()` and hardcodes CSV_LOTE when we already
    know the zip contained only CSVs.

36. **`_subir_servico()` must not recreate healthy containers.**
    `docker compose up -d <service>` **recreates** the container even if already running,
    resetting the healthcheck timer to `starting`. The wait loop then times out (120s) waiting
    for a health that may arrive after the timeout.
    **Fix:** Check health first, early-return if healthy:
    ```python
    chk = subprocess.run(["docker", "inspect", "-f", "{{.State.Health.Status}}",
                          f"fblegado_{servico}"], capture_output=True, text=True, timeout=10)
    if chk.returncode == 0 and chk.stdout.strip() == "healthy":
        return True
    ```

37. **rclone `--format "stp"` causes timeout on Google Drive.** The `t` (timestamp) flag in `--format "stp"` forces rclone to stat every individual item, which takes >30s on folders with many files and causes the cron or script to exit silently. Always use `--format "sp"` (size + path only) for listing — it's significantly faster:
    ```bash
    # SLOW — times out:
    rclone lsf "gdrive:.../Backup/" --format "stp" --separator "|"
    # FAST — use this:
    rclone lsf "gdrive:.../Backup/" --format "sp" --separator "|"
    ```

38. **Watchdog script `PROJETO` resolves wrong when run from `~/.hermes/scripts/`.** The `$(dirname "${BASH_SOURCE[0]}")/..` pattern resolves to `~/.hermes/` instead of `~/conversor-backups/` when the script is copied to `~/.hermes/scripts/`. The script then uses wrong paths for the dedup DB and staging dir, exiting silently. **Fix:** Add a fallback that detects `.hermes` in the path and substitutes the absolute project path:
    ```bash
    PROJETO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    case "$(basename "$PROJETO")" in
        .hermes|hermes)
            PROJETO="/home/hermes/conversor-backups"
            ;;
    esac
    ```

39. **Cron script `~/.hermes/scripts/` diverges from repo silently.** Every time `scripts/migbot_kanban_watchdog.sh` is updated in the repo, the copy at `~/.hermes/scripts/` (where the cron actually runs) must be updated manually. There is no auto-sync. Always run:
    ```bash
    cp /home/hermes/conversor-backups/scripts/migbot_kanban_watchdog.sh \
      ~/.hermes/scripts/migbot_kanban_watchdog.sh
    ```
    Then verify with `diff` or `sha256sum`.

40. **`docker compose` as a standalone binary (not a CLI plugin) fails inside containers.** The `docker:27-cli` COPY'd binary only includes `docker`, not the `docker-compose` plugin. `docker compose -f file.yml up` inside the container fails with `unknown shorthand flag: 'f' in -f`. **Fix:** Install the compose plugin at container build/runtime:
    ```bash
    DOCKER_CONFIG=/usr/local/lib/docker/cli-plugins
    mkdir -p $DOCKER_CONFIG/
    curl -sSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
      -o $DOCKER_CONFIG/docker-compose
    chmod +x $DOCKER_CONFIG/docker-compose
    ```
    And remember: every `docker restart` or `docker compose recreate` wipes non-image files — the plugin must be re-installed if not in the Dockerfile.

41. **Watchdog file locks outlive cancelled tasks and block new backups.** The watchdog at `scripts/migbot_kanban_watchdog.sh` uses per-backup file locks at `data/staging/.watchdog_locks/<sanitized_name>/` with a 2h TTL (`LOCK_TTL_SEGUNDOS=7200`). When a kanban task is cancelled or archived before the lock expires, the lock directory persists and `mkdir` fails on the next cron tick — the watchdog exits silently believing the backup is already handled. **Symptom:** Watchdog runs fine (exit 0) but `NOVOS[]` stays empty. **Fix:** Always clean `data/staging/.watchdog_locks/*/` when clearing dedup, or shorten the TTL.

42. **Kanban board statuses `triage`, `todo`, `scheduled` are hardcoded in Hermes core and cannot be removed.** They do not interfere with the Migbot flow (the watchdog creates tasks directly as `ready`), but they cannot be deleted from the SQLite schema or CLI. Simply ignore them — they cost nothing.

## References

- `references/mcp-only-architecture.md` — MCP como única via de restauração (NUNCA migbot_bot.py direto no host)
- `docs/FLUXO_PROJETO.md` (in repo) — full end-to-end project flow with token table and directory architecture
- `references/portability.md` — Export/import project between VPS (scripts + hermes-config repo)
- `references/worker-scope-and-data.md` — What the LLM worker sees vs doesn't see
- `references/continuous-learning.md` — Learn engine schema, flow, integration patterns
- `references/firebird-restoration.md` — Full Firebird pipeline playbook
- `references/firebird-composto-fix.md` — Patch for COMPOSTO handler
- `references/mcp-server.md` — MCP server setup and tools
- `references/restore-commands.md` — SGBD-specific commands and magic bytes
- `references/rclone-cloud-storage-setup.md` — rclone + Google Drive setup
- `references/troubleshooting-silent-watchdog.md` — Watchdog runs silent (Drive path mismatch)
- `references/token-consumption-benchmarks.md` — Token benchmarks per approach
- `references/failure-recovery-plan.md` — Step-by-step recovery per failure mode
- `references/csv-import-troubleshooting.md` — CSV encoding/delimiter failures and workarounds
- `references/async-delegation.md` — Delegating long restores to subagents
- `references/csv-lote-zip-path-fix.md` — ZIP-to-CSV_LOTE path fixes (redetection, sgbd_manual propagation, ZIP removal path)
- `references/gitignore-runtime-artifacts.md` — .gitignore patterns for DB restore projects (runtime vs code, exceptions for dedup DBs)
- `references/docker-inside-container.md` — Docker-from-inside-container: sg, compose, bind-mount paths, healthcheck recreation
- `references/docker-cp-timeout-pipe-fix.md` — docker cp 120s timeout fix
- `references/kanban-trigger.md` — Kanban trigger workflow
- `scripts/watchdog-gdrive.py` — Reference watchdog script (legacy, kanban preferred)
- `scripts/migbot_kanban_watchdog.sh` — Active kanban watchdog

*(The old `scripts/sofia_kanban_watchdog.sh` was renamed to `migbot_kanban_watchdog.sh` in
the repo. Update any cron that still points to the old name.)*
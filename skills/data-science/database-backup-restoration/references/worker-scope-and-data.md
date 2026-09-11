# Worker Scope & Data Access Model

## What the Worker (LLM) Sees vs Doesn't See

This is a frequently-asked question about how the restoration pipeline handles data privacy.

### ✅ Metadata (visible to the LLM)

| What | Example | Source |
|------|---------|--------|
| File names | `MUNDO1_BANCO_DADOS.zip` | stdout |
| File sizes | `12MB` | stdout |
| Compression format | `.zip` (password-protected) | `format_detector.py` |
| Inner format | `.GDB` → Firebird ODS 11 | `format_detector.py` |
| SGBD | `firebird` → `sqlserver` (after migration) | `restore_engine.py` output |
| Table names | `aluno`, `notas`, `msg_msg_logs` | stdout from import |
| Row counts | `82.753 linhas em msg_msg_logs` | stdout |
| Error messages | `Formato composto não pôde ser identificado` | traceback output |
| Code & configs | All `.py` files, `.json`, `.sh` | direct file read |
| Credential endpoints | `localhost:1433`, user `sa` | config values |
| Docker container states | `Running`, `healthy`, `exited` | `docker inspect` |

### ❌ Raw Data (NOT visible to the LLM)

| What | Why |
|------|-----|
| Individual rows of any table | Never read by the bot — only pandas/SQLAlchemy inside the container |
| Cell values (CPF, names, grades) | `migbot_bot.py` only prints aggregated counts, never cell contents |
| File binary contents | `format_detector.py` reads only first 20 bytes for magic/ODS |
| SQL query results on production data | Validation queries run inside Docker, only count(*) returned |
| CSV row contents | `pandas.read_csv` runs in pure Python, not LLM |

### How data flows (and where the LLM sits)

```
Backup file (.fdb, .sql, .bak)
     │
     ▼
[format_detector.py]  ← reads first 20 bytes only → ODS, checksum
     │
     ▼
[restore_engine.py]   ← orchestrates Docker containers
     │                    connects to MySQL/PG/SQL Server inside container
     │                    migrar_tabelas_para_sqlserver() moves data
     │                    between containers via pandas/sqlalchemy
     │
     ▼
[migbot_bot.py]       ← prints to stdout: "N tabelas criadas, X linhas"
     │                    NEVER prints cell contents, only counts
     │
     ▼
[stdout]              ← this is ALL the LLM worker ever sees
     │                    Table names ✓   Row counts ✓
     │                    Cell values ✗   SQL results ✗
     ▼
[LLM Worker]          ← operates on metadata + code only
                        can read .py files for debugging
                        can NOT read database contents
```

### Why this matters for debugging

When the pipeline breaks, the worker **reads the code** (`.py` files), **not the data**:

```python
# Worker sees this error:
File "restore_engine.py", line 1230, in restaurar
  "Formato composto não pôde ser identificado após extração."

# Worker does:
cat restore_engine.py → "ah, não tem handler firebird no COMPOSTO"
patch                → adds the elif → re-runs
```

The worker can fix the pipeline because it reads the Python source. It cannot fix the data because it never sees the data.

## Worker vs Script

The worker is an **orchestrator + debugger**, not a replacement for the Migbot scripts:

```
Worker (LLM reasoning layer)
   │
   ├── Decides WHAT to do:
   │     "vou baixar o arquivo"  →  runs rclone copy
   │     "vou rodar o migbot"    →  runs migbot_bot.py
   │     "deu erro, vou ler"     →  cat restore_engine.py
   │     "preciso corrigir"      →  patch the file
   │     "vou tentar de novo"    →  re-run migbot_bot.py
   │
   └── LETS the scripts do the HEAVY LIFTING:
         format_detector.py      — magic bytes, ODS, compression
         restore_engine.py       — RESTORE DATABASE, mysql < file
         firebird_format.py      — Docker Firebird, dump_firebird.py
         _shared.py              — migrar_tabelas_para_sqlserver
         learn_engine.py         — persist/query knowledge
```

**The worker never reinvents the wheel.** It uses the project's scripts for all heavy work. It only enters debugging mode when something new appears (e.g., Firebird wasn't in the COMPOSTO handler — worker discovered the gap and patched it once).

## Token efficiency

| What | Tokens |
|------|--------|
| Watchdog detection (cron, no_agent) | 0 |
| Kanban dispatch | ~0 |
| **Worker session** (download + restore + learn) | **30-50K** |
| Same task in main chat | 330K+ |
| **Economy** | **~85%** |
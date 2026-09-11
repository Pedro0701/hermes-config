# Restoration Progress Monitoring

## When to use this reference

The MCP tool `status_job()` returns `"status": "RESTAURANDO"` but no temporary Docker container appeared. You need to determine whether the restoration is actually progressing or stuck.

## Diagnostic checklist

### 1. Basic MCP health

Start with MCP health — check `restore_lock`:
```python
mcp__migbot__health()
# → {"restore_lock": true}  ← locked means the handler is active
# → {"restore_lock": false} ← handler finished or crashed
```

### 2. Check the job JSON

The MCP container stores job state at `/app/data/jobs/<job_id>.json`:
```bash
docker exec migbot_mcp cat /app/data/jobs/<job_id>.json
```

Look for the `logs` array — each entry is a timestamped step. If the last
log entry is more than 5-10 minutes old and no I/O is happening, the restore
may be stuck.

### 3. Check MCP container logs

```bash
docker logs migbot_mcp --tail 50
```

Key phrases to look for:
- `"Filtrando dump: removendo functions, procedures e triggers..."` — filtering a large SQL dump (can take minutes for GB-sized files)
- `"Iniciando import MySQL para banco..."` — about to start MySQL import
- `"MySQL falhou:"` — error during MySQL import (will probably try SQL Server fallback)
- `"Erro ao importar no MySQL: [Errno 21] Is a directory"` — directory-vs-file confusion from a previous run's staging
- `"Iniciando import SQL Server para banco..."` — MySQL failed, falling back to SQL Server

### 4. Check staging directory for job artifacts

```bash
docker exec migbot_mcp ls -la /app/data/staging/<job_id>/
```

Expected files at different stages:

| File | What it means | Status |
|------|---------------|--------|
| `arquivo_original.sql` (12GB) | Raw dump copied to staging | ✅ Received |
| `arquivo_original.sql.apenas_tabelas` (smaller) | Filtering done — functions/procs/triggers stripped | ✅ Filtered |
| `arquivo_original.sql.processado` | SQL Server batch processing applied | ✅ Processed |

The `.apenas_tabelas` file size relative to the original tells you how much
was stripped (typically 10-20% for MySQL dumps with lots of routines).

**File modification timestamps** show whether work is ongoing —
`ls -la` shows `mtime`. If the newest file is >5min old and has
stopped growing, the process may be stalled.

### 5. Check process I/O (is it still working?)

The MCP container runs one process (uvicorn/Python, PID 1). Check its
I/O counters and see if they're increasing over time:

```bash
# First read
docker exec migbot_mcp cat /proc/1/io
# Note read_bytes + write_bytes

# Wait 10-15 seconds
sleep 10 && docker exec migbot_mcp cat /proc/1/io
# If read_bytes and write_bytes increased → actively working
# If unchanged → likely stuck or waiting on something
```

Typical activity during a large MySQL SQL restore:
- **Filtering phase:** read_bytes + write_bytes both climb rapidly as the SQL file is parsed, routines removed, and the `.apenas_tabelas` output written
- **MySQL import phase:** write_bytes climbs as data flows into MySQL via Docker socket (the writes go into the MySQL container's storage, so host-level I/O counters on the MCP container may show lower activity)
- **SQL Server migration phase:** read/write mix as pandas reads from MySQL and writes to SQL Server

### 6. Check process thread state

```bash
docker exec migbot_mcp sh -c 'for tid in /proc/1/task/*/; do
  echo "--- $tid ---"
  grep -E "Name|State" "$tid/status" 2>/dev/null
  cat "$tid/wchan" 2>/dev/null
done'
```

- `R (running)` with wchan `0` → actively executing
- `S (sleeping)` with wchan `futex_wait_queue` → waiting on mutex (normal for async workers)
- `S (sleeping)` with wchan `ep_poll` → waiting for network (main thread)
- `D (uninterruptible sleep)` → blocked on I/O (disk wait — large file operations)
- `S (sleeping)` with wchan longer than 60s → potential stall

### 7. Check for previously-failed sibling jobs

Same backup file may have been attempted before. Check the jobs list:

```python
mcp__migbot__listar_jobs(limite=10)
```

If the same file has a `FALHA` entry right before the current `RESTAURANDO`
one, compare the logs to see what changed:

```python
mcp__migbot__status_job(job_id="<failed_job_id>")
```

Common recurring failures:
- `[Errno 21] Is a directory` — a previous run left a directory where a file was expected; the current run may have created its own staging dir correctly
- MySQL password/auth errors — fixed by using `MYSQL_ROOT_PASSWORD` from `.env`

### 8. Expected timeline for large files

| File size | Filtering (MySQL dump) | MySQL import | SQL Server migration | Total (approx) |
|-----------|----------------------|--------------|---------------------|----------------|
| 1 GB | 30s-1min | 2-5min | 3-8min | 6-15min |
| 5 GB | 2-4min | 10-20min | 15-30min | 30-55min |
| 10 GB | 4-8min | 20-40min | 30-60min | 55-110min |
| 12+ GB | 5-10min | 30-60min | 45-90min | 80-180min |

These are rough estimates on an SSD host with 196GB disk. Heavy INSERT batches,
constraints, and indexes add significant time.

### 9. When to consider it stuck

A restore is likely stuck if ALL of:
- Status remains `RESTAURANDO` for >15min past the expected timeline
- I/O counters haven't changed in >2min
- No new files in staging dir in >5min
- No new log entries in the job JSON

In that case, the lock is held by the MCP. The only recovery options:
- Wait for the MCP's 2h lock TTL to expire (`restore_lock` auto-clears)
- Restart the MCP container: `docker restart migbot_mcp`
- Reset dedup entry and retry with a fresh job

**Do NOT manually kill PID 1 inside the container** — it's the uvicorn process
and will terminate all in-flight operations, then auto-restart via Docker's
restart policy.
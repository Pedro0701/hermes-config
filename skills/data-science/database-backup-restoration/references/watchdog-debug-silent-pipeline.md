# Watchdog Debug: Why the Pipeline Was Silent

## Symptom

The `MigBot Watchdog` cron (every 15min, `no_agent=true`) reported `ok` but
never created kanban tasks. Users added backups to Google Drive but nothing
happened.

## Root Causes (chained)

### 1. Drive path typo (`Conversosr` vs `Conversor`)

The cron copy at `~/.hermes/scripts/migbot_kanban_watchdog.sh` had:
```bash
BACKUP_REMOTO="gdrive:1.Profissional/Conversosr/Backup/"
```
While `migbot/core/config.py` had the correct path:
```python
RCLONE_REMOTE_BASE = "gdrive:1.Profissional/Conversor"
```
`rclone lsf` returned `directory not found` → `MAPFILE` empty → silent exit.

**Why it diverged:** The script in `~/.hermes/scripts/` was an old copy from
before the `Conversosr` → `Conversor` fix in the repo. There is no auto-sync
— the cron copy must be manually updated after every script change.

### 2. PROJETO path resolution error

The script resolves `PROJETO` via:
```bash
PROJETO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```
When run from `~/.hermes/scripts/migbot_kanban_watchdog.sh`:
- `dirname ~/.hermes/scripts/migbot_kanban_watchdog.sh` → `~/.hermes/scripts/`
- `/..` → `~/.hermes/`
- Not the repo root

So `REGISTRO_DB` resolves to `~/.hermes/data/registro_backups.db` (which does
not exist, `sqlite3.connect` creates an empty one). The dedup check always
returns 0 (not found), *but the rclone fail from cause #1 exited first*.

### 3. rclone `--format "stp"` timeout

Even with the correct Drive path, `--format "stp"` (with timestamp flag `t`)
causes rclone to stat every remote item. On Google Drive with >3 items this
takes >30s, hitting the `timeout 30` or the cron's implicit timeout, returning
empty output.

## Fix Checklist

```bash
# 1. Sync script
cp /home/hermes/conversor-backups/scripts/migbot_kanban_watchdog.sh \
  ~/.hermes/scripts/migbot_kanban_watchdog.sh

# 2. Verify sync
diff ~/.hermes/scripts/migbot_kanban_watchdog.sh \
  /home/hermes/conversor-backups/scripts/migbot_kanban_watchdog.sh
# (no output = identical)

# 3. Test the script — should detect pending backups:
bash ~/.hermes/scripts/migbot_kanban_watchdog.sh
# Look for "📦 Novo backup detectado: ..." in output

# 4. Check kanban tasks created:
hermes kanban list

# 5. Confirm dispatcher active:
hermes gateway status
# Should show: active (running)

# 6. If no tasks appear, run with debug:
bash -x ~/.hermes/scripts/migbot_kanban_watchdog.sh 2>&1 | grep -E \
  "MAPFILE|NOVOS|processado|kanban|lock" | head -30
```

## Key Files

| Path | Role |
|------|------|
| `/home/hermes/conversor-backups/scripts/migbot_kanban_watchdog.sh` | Repo master |
| `~/.hermes/scripts/migbot_kanban_watchdog.sh` | Cron runtime copy |
| `/home/hermes/conversor-backups/data/registro_backups.db` | Dedup DB (watched by watchdog) |
| `/home/hermes/conversor-backups/data/staging/.watchdog_locks/` | Lock files preventing double-tasks |
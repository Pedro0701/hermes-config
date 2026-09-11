# Watchdog GDrive — Auto-restore via Google Drive

## Location
The canonical implementation lives at `~/conversor-backups/sofia/watchdog_gdrive.py`
in the user's project. A symlink-free copy is kept in `scripts/watchdog-gdrive.py`
here for reference.

## Architecture

```
cron (every 15m, no_agent=true)
  └─ bash wrapper (~/.hermes/scripts/sofia-watchdog.sh)
       └─ sources .env (so Telegram credentials are available)
       └─ exec python3 ~/conversor-backups/sofia/watchdog_gdrive.py
```

## Flow

1. **rclone lsf --format "stp"** — list files in GDrive Backup/ folder
   - Format: `size|ModTime|path`
   - Skip directories (trailing `/`)
   - Skip files with ModTime < 10 min ago (upload cooldown)
2. **Filter** — remove files whose name already appears in Resultado/
3. **Lock** — `/tmp/.sofia_watchdog.lock` via `fcntl.flock(LOCK_NB)`, TTL=2h
4. **Telegram notification** — sent immediately (before download)
5. **rclone copy** — download to local watch dir (timeout=3600s)
6. **SHA-256 dedup check** — verify vs registro_backups.db
7. **SofiaBot.processar_arquivo()** — actual restore
8. **rclone move** — move file from Backup/ to Resultado/{status}_{filename}
9. **Cleanup** — remove local file, release lock

## Key constants

| Constant | Value |
|----------|-------|
| Upload cooldown | 600s (10 min) |
| Lock TTL | 7200s (2h) |
| rclone copy timeout | 3600s (1h) |
| Watch dir | `~/conversor-backups/sofia/gdrive_watch/` |
| GDrive paths | `gdrive:1.Profissional/Sofia/Backup` and `.../Resultado` |

## Dependencies

```bash
python3 -m pip install pandas sqlalchemy pymysql --user --break-system-packages
```
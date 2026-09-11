# Parallel Restore Workflow — Detailed Reference

Session: 2026-07-21 — 3 backups from Google Drive restored in parallel.

## Scenario

3 backups in `gdrive:1.Profissional/Sofia/Backup/`:
- `dimensaonova.tar.gz` (1 GB) — compacted tar, heavy
- `teste_pg.sql.gz` (139 MB) — PostgreSQL dump
- `magnus/dados_magnus_csv.rar` (7 MB) — password-protected RAR with CSVs

Password for the RAR in `magnus/senha_bkp.txt`: `magnus2026*`

## VM Resources (check before starting)

```
CPU: 5 cores
RAM: 15 GB total, 8.3 GB available
Disk: 138 GB free
Containers: sqlserver_migrados, mysql_migrados, postgres_migrados (all Up)
```

## Strategy: 2 light parallel → 1 heavy solo

```
Phase 1 (parallel downloads):
  ├── rclone copy teste_pg.sql.gz      (139 MB, ~21 min)
  ├── rclone copy dados_magnus_csv.rar (7 MB, ~1 min)
  └── rclone copy dimensaonova.tar.gz  (1 GB, started early, download only)

Phase 2 (parallel restorations):
  ├── delegate_task → SofiaBot restaurar RAR (7 MB, 84s, 30 tables → SQL Server)
  └── delegate_task → SofiaBot restaurar SQL (133 MB, PostgreSQL)
        └── Start as soon as download finishes, don't wait for heavy file

Phase 3 (solo):
  └── SofiaBot restaurar TAR.GZ (1 GB, alone, after others complete)
```

## Key Decisions

1. **Start heavy download immediately** — the 1 GB file downloads while light
   restorations run. 45% overlap achieved.

2. **Don't wait for all downloads** — start restoring the RAR (complete in 1 min)
   while the SQL is still at 8%.

3. **Use delegate_task for restorations** — each restore gets its own subagent
   with isolated context. The parent keeps monitoring downloads and VM health.

4. **Estimate RAM before parallel runs:** ~1.2 GB extra for 2 parallel jobs +
   containers. 8.3 GB available → OK for 2, tight for 3.

## Bugs Found and Fixed During This Session

### Bug A: `--senha` flag ignored for individual files
`detectar_formato()` called without `senha=` kwarg in `sofia_bot.py:140`.
Password only reached `detectar_formato_pasta()`. Fixed by adding `senha=senha_manual`.

### Bug B: CSV_LOTE not detected after RAR extraction
Staging directory contained both `.rar` and extracted `.csv` files.
`detectar_formato_pasta()` rejects mixed directories. Fixed by:
1. Deleting the `.rar` from staging before re-detection
2. Adding `elif formato.formato_interno == CSV` branch in `sofia_bot.py`

### Bug C: Database name = job_id instead of original filename
`restaurar()` derives name from `Path(caminho_arquivo).stem`. When `caminho_arquivo`
is a staging directory, `.stem` returns the directory name (job_id). Fixed by
adding `nome_banco_override` parameter.

## Verification

```
Commit: ac981a3 → github.com:Pedro0707/Conversor.git
7 files changed, 448 insertions(+), 43 deletions(-)
Verification script: /tmp/hermes-verify-nome-banco.py (5/5 passed)
```

# Failure Recovery Plan for Backup Restorations

## Diagnostic — Find Failed Jobs

```bash
cd /home/hermes/conversor-backups
python3 -c "
from registro_backups import RegistroBackups
reg = RegistroBackups()
for r in reg.listar():
    if r['status'] == 'FALHA':
        print(f\"❌ {r['nome_arquivo']}: {r['detalhes']} (hash={r['hash_arquivo'][:12]})\")
"
```

Or inspect a specific job JSON:
```bash
cat migbot/jobs/<job_id>.json | python3 -m json.tool
```

## Recovery by Failure Mode

### 1. Password Required (archive is .rar/.7z with protection)

**Symptom:** Job stuck on `AGUARDANDO_SENHA`, Telegram asked for password.

**Action:** Locate `senha_bkp.txt` alongside the archive on Drive, download it, retry:
```bash
rclone copy "gdrive:path/to/senha_bkp.txt" /tmp/
SENHA=$(cat /tmp/senha_bkp.txt)
PYTHONPATH=. python3 migbot/migbot_bot.py <staging_path> --senha "$SENHA"
```

**Pitfall:** If a `.rar` was already extracted but password files weren't found by `_localizar_arquivo_senha()`, the bot may have skipped the rar and left extracted CSVs in staging. Check: `ls <staging_dir>/` for mixed `.rar` + `.csv` files.

### 2. Unknown Format

**Symptom:** Job `AGUARDANDO_INFO`, bot couldn't identify SGBD.

**Action:** Provide SGBD manually:
```bash
PYTHONPATH=. python3 migbot/migbot_bot.py <file_or_dir> --sgbd sqlserver
# or --sgbd mysql, --sgbd postgresql
```

### 3. Container Unavailable

**Symptom:** Job `FALHA` with "Container X não disponível".

**Action:** Start containers and retry:
```bash
sg docker -c "docker start sqlserver_migrados mysql_migrados postgres_migrados"
# Or recreate from compose:
cd /home/hermes/conversor-backups/sistemas_migrados
sg docker -c "docker compose up -d"
```

After recovery, reset the dedup entry and re-import:
```bash
python3 -c "
from registro_backups import RegistroBackups
reg = RegistroBackups()
for r in reg.listar():
    if r['status'] == 'FALHA':
        reg.resetar(r['hash_arquivo'][:12])
        print(f'Reset: {r[\"nome_arquivo\"]}')
"
```

### 4. Partial CSV Import (one-failure-stops-all)

**Symptom:** Job `FALHA` — some CSVs imported, one broke mid-batch.

**Background:** `restaurar_csv_lote()` commits each CSV with `to_sql(if_exists="replace")` before moving to the next. The failing CSV and all subsequent ones are missing, but earlier ones have data.

**Actions:**
- **A)** Find which CSV broke, fix the encoding/delimiter issue, import just that CSV:
  ```bash
  PYTHONPATH=. python3 -c "
  from migbot.core.restore_engine import RestoreEngine
  e = RestoreEngine('manual', '/tmp')
  r = e.restaurar_csv('path/to/broken.csv', 'nome_banco', sgbd_destino='sqlserver')
  print(r.sucesso, r.mensagem)
  "
  ```
- **B)** Drop the database and re-import the whole batch after fixing the source.

**CSV diagnosis:**
```bash
python3 -c "
import pandas as pd
for enc in ['utf-8', 'latin1', 'cp1252', 'iso-8859-1']:
    try:
        df = pd.read_csv('arquivo.csv', encoding=enc, nrows=5, sep=None, engine='python')
        print(f'OK: {enc}, cols={list(df.columns)}')
        break
    except Exception as e:
        print(f'{enc}: {e}')
"
head -3 arquivo.csv | cat -v
```

### 5. Dedup Entry Stuck as EM_ANDAMENTO

**Symptom:** Job crashed mid-flight (VM reboot, timeout). Registry shows `EM_ANDAMENTO`, can't reprocess.

**Action:** Reset the stuck entry:
```bash
python3 -c "
from registro_backups import RegistroBackups
reg = RegistroBackups()
for r in reg.listar():
    if r['status'] == 'EM_ANDAMENTO':
        print(f'Reset: {r[\"nome_arquivo\"]} ({r[\"hash_arquivo\"][:12]})')
        reg.resetar(r['hash_arquivo'][:12])
"
```

### 6. Export Skipped (System Not Identified)

**Symptom:** Job `CONCLUIDO` but no export CSVs on Drive. Caused by missing `[sistema]` prefix in the local folder name.

**Action:** Run export manually:
```bash
PYTHONPATH=. python3 -m migbot.core.export_engine <sistema> <cliente> \\
  --banco <nome_banco> --sgbd <sqlserver|mysql> --upload
```

### 7. PostgreSQL Wrong Database (\\connect redirect)

**Symptom:** Job `CONCLUIDO` with "0 tables" in the Sofia-created database. The dump's `\\connect` redirected data to a different database.

**Detection:**
```bash
docker exec postgres_migrados psql -U postgres -l
docker exec postgres_migrados psql -U postgres -d <candidate> -c "\dt"
```

**Resolution:** Either rename the real database to match Sofia's name, or drop the empty one and use the real database directly.

### 8. Dedup Says CONCLUIDO but Database is Gone

**Symptom:** Sofia says "already imported" with old credentials, but the database doesn't exist (container was recreated).

**Action:** Reset dedup from CONCLUIDO to PENDENTE:
```bash
python3 -c "
import sqlite3
db = sqlite3.connect('sistemas_migrados/registro_backups.db')
hash_alvo = '80be6241...'  # from job output
db.execute('UPDATE backups_importados SET status = ? WHERE hash_arquivo LIKE ?',
           ('PENDENTE', f'{hash_alvo}%'))
db.commit()
print(f'Entry {hash_alvo} reset to PENDENTE')
"
```

## Fallback Recovery Strategies (Built-In)

The MigBot engine **automatically** falls back for these cases — no manual action needed unless both fail:

| Format | Primary SGBD | Fallback |
|--------|-------------|----------|
| `.bak` | SQL Server | MySQL (if content looks like SQL) |
| `.sql` MySQL | MySQL | SQL Server |
| `.csv` | SQL Server | MySQL |
| PostgreSQL | Container Docker | Local `psql` |

## Full Reprocess Flow

```
Job falhou?
   │
   ├─ Container parado?  → docker start → reset dedup → re-run
   ├─ Senha ausente?     → --senha flag → re-run
   ├─ Formato desconhec.?→ --sgbd flag → re-run
   ├─ Import parcial?    → importar CSV faltante manualmente
   ├─ Stuck EM_ANDAMENTO?→ reset dedup → re-run
   └─ Dedup falso CONCLUIDO? → reset dedup → re-run
```
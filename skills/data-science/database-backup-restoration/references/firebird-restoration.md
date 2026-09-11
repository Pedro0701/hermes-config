# Firebird Restoration Playbook

Full pipeline for restoring `.fdb`/`.gdb`/`.fbk` backups (Firebird/InterBase)
into SQL Server, as implemented in `migbot/core/formats/firebird_format.py`.
Hard-won from the MUNDO1_BANCO_DADOS restore (ODS 11, 83MB .GDB, 192 tables).

## Pipeline

```
.fdb/.gdb detected (checksum 12345 @ offset 2, ODS @ offset 18)
  → ODS → container: 10=fb15, 11=fb25, 12=fb30, 13=fb40
  → copy .fdb to docker/firebird-legado/data/<job_id>/<job_id>.fdb
  → docker compose up -d <servico>  (wait for HEALTHY, not just Running)
  → dump-dados.sh → dump_firebird.py → CSV per table (+ .sqlite)
  → restaurar_csv_lote(csv_dir, banco, sgbd_destino="sqlserver")
```

Credentials: `SYSDBA` / `masterkey`. Ports: fb25=3050, fb30=3053, fb40=3054, fb50=3055.

## Pitfalls (bugs hit in practice)

1. **`_PROJETO` path resolution.** `firebird_format.py` lives at
   `migbot/core/formats/`, so the repo root is **parent × 4**, not ×3:
   ```python
   _PROJETO = Path(__file__).resolve().parent.parent.parent.parent  # conversor-backups/
   ```
   A ×3 resolves to `migbot/` and the harness path silently points nowhere.

2. **Wait for `healthy`, not `Running`.** Firebird containers report `Running`
   (and pass a `.State.Running` check) *before* the engine is ready to accept
   connections. Poll `docker inspect -f '{{.State.Health.Status}}' fblegado_<svc>`
   until `healthy` (up to ~120s). Dump fails with a truncated
   `firebirdsql/fbcore.py _op_response` trace if you connect too early.

3. **Python 3.12 sqlite3 adapters.** `dump_firebird.py` inserts into SQLite.
   Python 3.12 removed default adapters for date/time/datetime and never had
   one for `Decimal`. Failure stream: `dbd0b...` — trace ends at
   `sq.executemany(ins, batch)` with `sqlite3.ProgrammingError: Error binding
   parameter N: type 'decimal.Decimal' is not supported` (then `datetime.time`).
   Register adapters at module import:
   ```python
   import datetime
   from decimal import Decimal
   def _adapt_date(d): return d.isoformat()
   def _adapt_datetime(dt): return dt.isoformat()
   def _adapt_decimal(d): return str(d)
   sqlite3.register_adapter(datetime.date, _adapt_date)
   sqlite3.register_adapter(datetime.datetime, _adapt_datetime)
   sqlite3.register_adapter(datetime.time, lambda t: str(t))
   sqlite3.register_adapter(Decimal, _adapt_decimal)
   ```

4. **Case-insensitive extension search.** Backup archives can contain
   `MUNDO1_BANCO_DADOS.GDB` (uppercase). Both `migbot_bot.py` candidate search
   and `restore_engine.py`'s COMPOSTO `fb_files` scan must use
   `f.lower().endswith(".fdb"/".gdb")` and `rglob("*.GDB")`/`rglob("*.FDB")`.

5. **COMPOSTO handler must NOT use `arquivos_internos` paths.** Those point at
   the temp extraction dir which is already deleted by the time `restaurar()`
   runs. Search `Path(caminho_arquivo).rglob("*.fdb"/"*.gdb"/upper variants)`
   in staging instead. See `references/firebird-composto-fix.md`.

6. **Local `data/` dir owned by root.** Running the alpine chown once fixes the
   bind mount permissions so `shutil.copy2` into `docker/firebird-legado/data/`
   works without sudo:
   ```bash
   sg docker -c "docker run --rm -v <repo>/docker/firebird-legado/data:/data \
     alpine chown -R 1000:1000 /data"
   ```
   (Since this is a one-time env fix, do it as setup, not as a code path.)

7. **`bash ./dump-dados.sh` inside `sg docker -c` needs the absolute path.**
   `cd <dir> && bash <dir>/dump-dados.sh` — a bare `./dump-dados.sh` can fail
   with "Arquivo ou diretório inexistente" because the sg wrapper doesn't
   preserve cwd the way you'd expect in subprocess.run.

8. **Dump output dir carries the sqlite file too.** The dump succeeds and CSVs
   land in `data/<job_id>/dump_<job_id>/csv/` even when the .sqlite write fails;
   check `result.returncode == 0` and that the csv dir exists before trusting it.

## Verification recipe

Synthetic Firebird header (no real file needed) to test `_detectar_ods` / `_verificar_firebird`:
```python
import struct, tempfile, os
with tempfile.NamedTemporaryFile(suffix=".fdb", delete=False) as f:
    f.write(b"\x00\x00" + struct.pack("<H", 12345) + b"\x00"*12 + struct.pack("<HH", 4096, 11))
    fn = f.name
info = _detectar_ods(fn); os.unlink(fn)
assert info["valido"] and info["servico"] == "fb25" and info["pagesize"] == 4096
```
ODS 10→fb15, 11→fb25, 12→fb30, 13→fb40; bad checksum (≠12345) → invalid.
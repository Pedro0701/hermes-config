---
name: database-backup-restore
description: >-
  Detect, extract, filter, and restore database backups (MySQL/SQL
  Server/PostgreSQL) from files of various formats. Covers magic-bytes detection,
  compression unwinding, streaming filter for large dumps, Docker-less fallback,
  and deduplication.
category: data-science
---

# Database Backup Restore

Restore database backups from uploaded files: detect format → extract → filter
→ restore to a running server → validate → notify.

## Format Detection Pipeline

1. **Magic bytes** — read first 32 bytes; detect gzip (`\x1f\x8b\x08`), zip
   (`PK\x03\x04`), bzip2, xz, 7z, rar.
2. **TAR fallback** — if no known magic, try `tarfile.is_tarfile(path)`.
   Plain TAR files have **no universal magic** but `is_tarfile()` reads the
   POSIX header block at byte 0.
3. **Extension as hint** — `.bak` → SQL Server, `.csv` → CSV import,
   `.sql` → content analysis for SGBD markers.
4. **Content SQL detection** — scan first 500 chars for:
   - MySQL: `-- MySQL dump`, `ENGINE=InnoDB`, backtick quoting, `AUTO_INCREMENT`
   - SQL Server: `USE [`, `SET ANSI_NULLS`, `[dbo]`, `IDENTITY_INSERT`
   - PostgreSQL: `-- PostgreSQL database dump`, `COPY`, `SET statement_timeout`
5. **Nested unwinding** — TAR → .sql.gz → MySQL should resolve `formato_interno`
   to `MYSQL_SQL` (the innermost), not `COMPOSTO` (the gzip layer). Walk
   `inner_result.formato_interno` until you hit a non-COMPOSTO enum value.

## Compression Handling

| Format | Extraction |
|--------|-----------|
| .gz | `gzip.open(src)` → write dest |
| .zip | `zipfile.ZipFile(src).extractall(dst)` |
| .tar / .tar.gz | `tarfile.open(src, 'r:*')` — auto-detects gzip |
| .rar | `unrar x` or `7z x` |
| .7z | `7z x` |
| .bz2 | `bz2.open(src)` → write dest |
| .xz | `lzma.open(src)` → write dest |

**Temp dir lifecycle**: extract to `tempfile.mkdtemp()`, preserve the path
in the result object (`resultado.temp_dir_extraido`). The **caller** (not the
detector) is responsible for cleanup via `shutil.rmtree()`.

## Restore by SGBD

### MySQL (Docker or binary)
```bash
# Create DB
mysql -uroot -p'PASS' -h 127.0.0.1 -P 3307 \
  -e "CREATE DATABASE IF NOT EXISTS \`dbname\` CHARACTER SET utf8mb4;"

# Import with filter (avoids writing 2x disk)
python3 filtrar_stream.py < dump.sql |
  mysql -uroot -p'PASS' -h 127.0.0.1 -P 3307 \
    --max_allowed_packet=1G \
    --init-command="SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0; SET AUTOCOMMIT=0;" \
    dbname

# Validate
mysql -uroot -p'PASS' -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='dbname';"
```

### MySQL without Docker (userspace binary)
```bash
MYSQL_DIR="/tmp/mysql-8.0.36-linux-glibc2.28-x86_64"
export LD_LIBRARY_PATH=/home/hermes:$LD_LIBRARY_PATH

# Initialize (one-time)
$MYSQL_DIR/bin/mysqld --no-defaults --initialize-insecure \
  --user=hermes --datadir=/home/hermes/mysql_data

# Start
$MYSQL_DIR/bin/mysqld --datadir=/home/hermes/mysql_data \
  --socket=/home/hermes/mysql.sock --port=3307 \
  --pid-file=/home/hermes/mysql.pid \
  --log-error=/home/hermes/mysql_data/mysqld.log \
  --max_allowed_packet=1G

# Set root password (stop, start with --skip-grant-tables --skip-networking,
# run FLUSH PRIVILEGES; ALTER USER..., then restart with networking)
```

**libaio gotcha**: system may have `libaio.so.1t64` (new naming) while MySQL
expects `libaio.so.1`. Symlink fixes it:
```bash
ln -sf /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /home/hermes/libaio.so.1
export LD_LIBRARY_PATH=/home/hermes:$LD_LIBRARY_PATH
```

### SQL Server (Docker container)
```bash
docker exec -i sqlserver_migrados sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
  -Q "RESTORE DATABASE [dbname] FROM DISK = N'/var/opt/mssql/backup/file.bak'
      WITH MOVE N'logical_data' TO N'/var/opt/mssql/data/dbname.mdf',
           MOVE N'logical_log' TO N'/var/opt/mssql/data/dbname_log.ldf',
           RECOVERY, STATS = 10"
```

## Streaming Filter for Large Dumps

For dumps >2GB, **never write a second copy to disk** — pipe through a filter
that reads stdin, writes filtered stdout:

```python
import re, sys
MARCADORES = (b"DROP VIEW", b"CREATE VIEW", b"CREATE ALGORITHM",
              b"DROP TRIGGER", b"CREATE TRIGGER",
              b"DROP PROCEDURE", b"CREATE PROCEDURE",
              b"DROP FUNCTION", b"CREATE FUNCTION")
VERSIONED = re.compile(rb"/\*!\d+\s?|\*/")

for linha in sys.stdin.buffer:
    efetiva = VERSIONED.sub(b'', linha).strip().upper()
    if any(efetiva.startswith(m) for m in MARCADORES):
        continue
    sys.stdout.buffer.write(linha)
```

Run: `python3 filter.py < dump.sql | mysql ... dbname`

## Deduplication

Use SHA-256 hash of file *content* (not filename) as dedup key. Store in
SQLite: `CREATE TABLE backups (hash TEXT PRIMARY KEY, status TEXT, ...)`.
Backups with `status='CONCLUIDO'` are skipped; `FALHA` can be reprocessed.

## Pitfalls

- **.tar.gz naming is unreliable.** The file may be a plain TAR despite the
  extension. Always check with `tarfile.is_tarfile()` and `file` command.
- **12GB dump → 12GB+ on disk after decompression.** Ensure sufficient space
  before extracting. Use streaming filter to avoid doubling.
- **MySQL root password without networking:** start with
  `--skip-grant-tables --skip-networking`, set password, restart.
- **`max_allowed_packet`** must be set **before** importing, or large INSERTs
  fail silently.
- **DEFINER users** in MySQL dumps from other servers must be created (even
  without privileges) or SOURCE fails with ERROR 1449.
- **Background mysqld** needs a pid-file for clean shutdown; use
  `mysqladmin shutdown` not `kill -9` to avoid data dir corruption.
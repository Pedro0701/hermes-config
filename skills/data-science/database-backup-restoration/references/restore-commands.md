# SGBD-Specific Restore Commands

## SQL Server (.bak)

```sql
-- Step 1: List files in backup
RESTORE FILELISTONLY FROM DISK = N'/path/backup.bak'

-- Step 2: Restore with MOVE (paths must be container-visible)
RESTORE DATABASE [nome_banco]
FROM DISK = N'/var/opt/mssql/backup/backup.bak'
WITH
  MOVE N'logical_data_name' TO N'/var/opt/mssql/data/nome_banco_logical.mdf',
  MOVE N'logical_log_name'  TO N'/var/opt/mssql/data/nome_banco_logical_log.ldf',
  RECOVERY,
  STATS = 10

-- Step 3: Verify online
SELECT state_desc FROM sys.databases WHERE name = 'nome_banco'
```

### Via sqlcmd (in container)
```bash
# Simple file import
sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d nome_banco -i /path/script.sql -b

# RESTORE with output file
sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
  -Q "RESTORE DATABASE [db] FROM DISK = N'/path/file.bak' WITH RECOVERY, STATS = 10" \
  -o /tmp/restore_log.txt -b
```

## MySQL (.sql)

```bash
# Create database
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e "CREATE DATABASE IF NOT EXISTS \`db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"

# Adjust packet size for large inserts
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e "SET GLOBAL max_allowed_packet=1073741824"

# Execute dump
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" db \
  --default-character-set=utf8mb4 \
  --max_allowed_packet=1G \
  -e "SOURCE /path/dump.sql"

# Verify
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'db'"
```

### Turbo mode (disable FK/UNIQUE checks)
```sql
SET SESSION FOREIGN_KEY_CHECKS=0;
SET SESSION UNIQUE_CHECKS=0;
SET SESSION AUTOCOMMIT=0;
-- ... run import ...
COMMIT;
```

## PostgreSQL (.sql)

```bash
# Via psql with environment variable for password
PGPASSWORD="$PG_PASSWORD" psql -U postgres -h localhost -p 5432 \
  -d nome_banco -f /path/dump.sql
```

### Creating the database first
```sql
CREATE DATABASE nome_banco;
```

## CSV Import (Python + SQLAlchemy)

```python
import pandas as pd
from sqlalchemy import create_engine

# Detect encoding
for enc in ["utf-8", "utf-8-sig", "cp1252", "latin-1"]:
    try:
        df = pd.read_csv("file.csv", encoding=enc, sep=None, engine="python")
        break
    except Exception:
        continue

# Normalize
df.columns = [c.strip().lower() for c in df.columns]

# Import (chunked for large files)
df.to_sql("tabela", engine, if_exists="replace", index=False, chunksize=1000)
```

## Container File Transfer Patterns

```bash
# docker cp (best for <1GB files)
docker cp local_file.bak container_name:/path/inside/container/

# stdin pipe (better for large files or flaky docker cp)
docker exec -i container_name sh -c 'cat > /path/inside/file.bak' < local_file.bak

# Ensure target directory exists first
docker exec container_name mkdir -p /path/inside/
```

## Magic Bytes Quick Reference

| Bytes (hex) | Format | Extension hints | Detection method |
|---|---|---|---|
| `1f 8b 08` | GZip | .gz, .sql.gz, .tar.gz | Magic bytes (reliable) |
| `50 4b 03 04` | ZIP | .zip, .docx, .xlsx | Magic bytes (reliable) |
| `52 61 72 21 1a 07` | RAR | .rar | Magic bytes (reliable) |
| `37 7a bc af 27 1c` | 7-Zip | .7z | Magic bytes (reliable) |
| `42 5a 68` | BZIP2 | .bz2, .tar.bz2 | Magic bytes (reliable) |
| `fd 37 7a 58 5a 00` | XZ | .xz, .tar.xz | Magic bytes (reliable) |
| `1f 9d` or `1f a0` | Compress (old TAR) | .tar.Z | Magic bytes (reliable) |
| **no fixed magic** | **TAR** | **.tar** | **`tarfile.is_tarfile()`** fallback |
| no fixed magic | SQL Server BAK | .bak | Extension + RESTORE HEADERONLY |
| no fixed magic | BACPAC | .bacpac | Extension + ZIP inspection |

**⚠️ TAR trap:** A file named `.tar.gz` may be a plain TAR (not gzipped).
Always check magic bytes first, then fall back to `tarfile.is_tarfile()`.
See `references/tar-magic-detection.md` for details.
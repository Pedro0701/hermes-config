# Firebird → MySQL Migration (Case Study)

## Source

- **Firebird container:** `firebird_teste` (IP 172.17.0.3, port 3050)
- **Credentials:** SYSDBA / masterkey
- **Database:** `/firebird/data/MUNDO1_BANCO_DADOS.GDB`
- **CLI tool:** `/usr/local/firebird/bin/isql`

## Target

- **MySQL container:** `mysql_migrados` (port 3307 → 3306)
- **Credentials:** root / `Sofia@2024!` (from `.env`)
- **Target database:** `mundo1_banco_dados` (utf8mb4)

## Script Location

`/home/hermes/conversor-backups/scripts/firebird_to_mysql.py`

## Firebird RDB$ Type Reference

| RDB$FIELD_TYPE | Name | Maps to | Notes |
|---|---|---|---|
| 7 | SMALLINT | SMALLINT | |
| 8 | INTEGER | INT | |
| 10 | FLOAT | FLOAT | |
| 12 | DATE | DATE | |
| 14 | CHAR(n) | CHAR(n) | Use RDB$CHARACTER_LENGTH |
| 16 | BIGINT | BIGINT | |
| 27 | DOUBLE | DOUBLE | |
| 35 | TIMESTAMP | TIMESTAMP | sub_type 6 = DATETIME(6) |
| 37 | VARCHAR(n) | VARCHAR(n) | Use RDB$CHARACTER_LENGTH |
| 40 | CSTRING | TEXT | |
| 45 | BLOB sub_1 | LONGTEXT | |
| 45 | BLOB other | LONGBLOB | |
| 261 | BLOB sub_1 | LONGTEXT | |
| 261 | BLOB other | LONGBLOB | |

## isql Key Queries

### List tables (non-system)
```sql
SELECT RDB$RELATION_NAME FROM RDB$RELATIONS
WHERE RDB$SYSTEM_FLAG = 0 AND RDB$VIEW_BLR IS NULL
ORDER BY RDB$RELATION_NAME;
```

### Get column metadata
```sql
SELECT rf.RDB$FIELD_NAME, f.RDB$FIELD_TYPE, f.RDB$FIELD_SUB_TYPE,
       f.RDB$FIELD_LENGTH, f.RDB$FIELD_PRECISION, f.RDB$FIELD_SCALE,
       f.RDB$CHARACTER_LENGTH, rf.RDB$NULL_FLAG
FROM RDB$RELATION_FIELDS rf
JOIN RDB$FIELDS f ON rf.RDB$FIELD_SOURCE = f.RDB$FIELD_NAME
WHERE rf.RDB$RELATION_NAME = 'TABLENAME'
ORDER BY rf.RDB$FIELD_POSITION;
```

### Get primary key
```sql
SELECT ix.RDB$FIELD_NAME FROM RDB$RELATION_CONSTRAINTS rc
JOIN RDB$INDEX_SEGMENTS ix ON rc.RDB$INDEX_NAME = ix.RDB$INDEX_NAME
WHERE rc.RDB$RELATION_NAME = 'TABLENAME'
AND rc.RDB$CONSTRAINT_TYPE = 'PRIMARY KEY'
ORDER BY ix.RDB$FIELD_POSITION;
```

## Data Export with SET LIST ON

```sql
SET LIST ON;
SET WIDTH 32767;
SELECT * FROM "TABLENAME";
```

Output format (highly parseable):
```
COLNAME1    value1
COLNAME2    value2
(blank line)
COLNAME1    ...
```

## Bugs Encountered & Fixed

1. **Missing pipe to docker exec.** SQL string was piped to `printf` but the result was never piped to docker exec. The `cmd` variable was defined but not referenced in the _run call.
2. **isql multi-page headers.** isql repeats the column header + `===` separator every ~20 rows. The parser was skipping the first header but processing subsequent ones as data rows. Fix: always skip lines containing `RDB$FIELD_NAME` or consisting only of `=` characters.
3. **BLOB display messages.** Lines like `BLOB display set to subtype 1` appear inline. Filtered by checking `startswith("BLOB display")`.
4. **Double quote escaping.** `safe_sql()` + `_sq()` both escaped single quotes, producing `'\\''` where `'\\''` was expected. Solution: remove `safe_sql()`, use only `_sq()`.
5. **SET LIST ON echo.** The `SET LIST ON` command itself was sometimes echoed as `SET` in the output. Filtered by checking `col_part == "SET"`.

## Remaining Work (at session end)

The script at session end had three stale references to the removed `safe_sql()` function. Replace with `_sq()` only:
- Line 283: `export_table_csv()` — `_sq(safe_sql(full_input))` → `_sq(full_input)`
- Line 436: `import_csv_mysql()` — `_sq(safe_sql(load_sql))` → `_sq(load_sql)`
- Line 461: `import_csv_mysql()` LOCAL fallback — `_sq(safe_sql(load_local_sql))` → `_sq(load_local_sql)`
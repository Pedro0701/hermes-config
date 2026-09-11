# Format Detection Deep-Reference

## Magic Bytes Reference Table

| Format | Magic Hex | Python Check |
|--------|-----------|--------------|
| gzip | `1f 8b 08` | `magic[:3] == b"\x1f\x8b\x08"` |
| zip | `50 4b 03 04` | `magic[:4] == b"PK\x03\x04"` |
| zip (empty) | `50 4b 05 06` | `magic[:4] == b"PK\x05\x06"` |
| rar | `52 61 72 21 1a 07 00` | `magic[:7] == b"Rar!\x1a\x07\x00"` |
| 7z | `37 7a bc af 27 1c` | `magic[:6] == b"\x37\x7a\xbc\xaf\x27\x1c"` |
| bzip2 | `42 5a 68` | `magic[:3] == b"BZh"` |
| xz | `fd 37 7a 58 61 00` | `magic[:6] == b"\xfd7zXZ\x00"` |
| tar (LZW) | `1f 9d` or `1f a0` | `magic[:2] in (b"\x1f\x9d", b"\x1f\xa0")` |
| **tar (plain)** | **none** | `tarfile.is_tarfile(path)` |

## SQL SGBD Detection by Content

Score-based detection: scan first 500 chars and count markers.

### MySQL markers (weight ~2 each)
- `-- MySQL dump` / `-- MariaDB dump`
- `ENGINE=InnoDB` / `ENGINE=MyISAM`
- `` ` `` (backtick quoting) + `CREATE TABLE` nearby
- `AUTO_INCREMENT`
- `LOCK TABLES` / `UNLOCK TABLES`
- `DEFINER=`
- `/*!40101 SET`

### SQL Server markers (weight ~2 each)
- `SET ANSI_NULLS` / `SET QUOTED_IDENTIFIER`
- `[dbo].` (bracket notation)
- `IDENTITY_INSERT`
- `USE [` (square bracket database names)
- `GO` as standalone line

### PostgreSQL markers (weight ~2 each)
- `-- PostgreSQL database dump`
- `COPY ` (with `FROM stdin` nearby)
- `SET statement_timeout`
- `SET lock_timeout`
- `SET standard_conforming_strings`

## Nested format example (novadimensao.tar.gz)

```
novadimensao.tar.gz (998MB)
  └── detected as: plain TAR (tarfile.is_tarfile)
      └── um_novadimensao.sql.gz (997MB)
          └── detected as: gzip
              └── um_novadimensao.sql (12GB)
                  └── detected as: MySQL dump (content analysis)
```

The `formato_interno` field on the top-level `ResultadoDeteccao` must unwind
to `MYSQL_SQL`, not stop at `COMPOSTO` (gzip layer). Implementation shortcut:
```python
profundo = interno_result.formato_interno
if isinstance(profundo, FormatoBackup) and profundo != FormatoBackup.COMPOSTO:
    resultado.formato_interno = profundo
else:
    resultado.formato_interno = interno_result.formato_primario
```

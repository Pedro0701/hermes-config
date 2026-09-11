# TAR Detection Quirk

## Problem

TAR has no universal magic bytes. Unlike every other archive format
(GZip = `1f8b08`, ZIP = `PK\x03\x04`, RAR = `Rar!\x1a\x07`, etc.),
a plain TAR archive begins with the first file's content bytes.

This means a file named `backup.tar.gz` can actually be a **plain TAR**
(not gzipped), with the `.gz` extension being misleading. Real-world
example: `novadimensao.tar.gz` (998MB) was a plain `POSIX tar archive (GNU)`
despite the `.tar.gz` name.

## Detection

```python
import tarfile

def detectar_compactacao(caminho):
    # ... check magic bytes for gzip, zip, rar, 7z, bzip2, xz ...
    # If nothing matches, try TAR as last resort:
    try:
        if tarfile.is_tarfile(caminho):
            return "tar"
    except Exception:
        pass
    return None
```

## Verification

```bash
file arquivo.tar.gz
# → "POSIX tar archive (GNU)"  = plain TAR, NOT gzipped
# → "gzip compressed data"     = actually gzipped
```

## Implications

1. A "tar.gz" that is actually a plain TAR extracts instantly (no decompression)
2. The `tarfile` module handles both cases (just use mode `r:*` or `r` for plain)
3. Files inside may still be `.sql.gz` (gzip compressed SQL) — you'll need
   `gzip` decompression for those
4. Always fall back to `tarfile.is_tarfile()` at the end of your compression
   detector — it's cheap (reads only the file header) and catches the no-magic case
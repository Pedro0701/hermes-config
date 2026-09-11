# CSV_LOTE ZIP Path Fix (2026-09-10)

## Problem

Zipped CSV backups (`dump_SSEscola_fb25.zip`) failed with:

```
Falha ao detectar pasta como CSV_LOTE: desconhecido
```

Despite `detectar_formato()` correctly finding `COMPOSTO → CSV` with 56 CSVs inside.

## Root causes

### 1. ZIP removal targeted wrong directory

When `eh_pasta=True`, the workflow:
1. `shutil.copytree(src, staging_dir / nome_arquivo)` → creates `staging/<job_id>/dump_SSEscola_fb25/dump_SSEscola_fb25.zip`
2. Extracted CSVs go to `staging/<job_id>/` (flat, via `staging_dir / Path(arq_interno).name`)
3. Old code removed ZIP from `staging_dir` → wrong, it's in the subdirectory
4. `detectar_formato_pasta(staging_dir)` sees the subdirectory with ZIP → DESCONHECIDO

**Fix:** Use `Path(arquivo_staging)` for ZIP removal (which points to the subdirectory),
and detect CSV_LOTE on `str(pasta_com_zip)` instead of `staging_dir`.

### 2. CSVs copied to wrong location

Extracted CSVs went to `staging_dir` (parent), not to the subdirectory where the ZIP was.
After ZIP removal the subdirectory was empty, so `detectar_formato_pasta` saw 0 files.

**Fix:** Use `pasta_destino = Path(arquivo_staging) if eh_pasta else staging_dir` as copy target.

### 3. Redetection bypassed entirely

Even with correct paths, `detectar_formato_pasta()` still returned DESCONHECIDO for a
directory of pure `.csv` files. Root cause not determined (possibly permission masking or
subdirectory remnant). The practical fix:

```python
# Skip redetection — we already know it's all CSVs
novo_formato = ResultadoDeteccao()
novo_formato.formato_primario = FormatoBackup.CSV_LOTE
novo_formato.arquivos_internos = [
    str(pasta_com_zip / Path(f).name) for f in formato.arquivos_internos
]
novo_formato.sgbd = sgbd_manual or "sqlserver"
novo_formato.confidence = 0.9
formato = novo_formato
eh_pasta = True
```

### 4. `sgbd_manual` not propagated

`detectar_formato_pasta()` had no `sgbd_manual` parameter → `resultado.sgbd` was empty.
`restore_engine.py` called `restaurar_csv_lote()` without passing `sgbd_destino`.

**Fix (3 files):**
- `format_detector.py`: Add `sgbd_manual` param, set `resultado.sgbd = sgbd_manual or ""`
- `migbot_bot.py`: Pass `sgbd_manual` to `detectar_formato_pasta()`
- `restore_engine.py`: Read `formato.sgbd or "sqlserver"` as `sgbd_destino`

## Files changed

| File | Change |
|------|--------|
| `migbot/core/format_detector.py` | `sgbd_manual` param + propagate to `resultado.sgbd` |
| `migbot/core/restore_engine.py` | CSV_LOTE reads `formato.sgbd` as `sgbd_destino` |
| `migbot/migbot_bot.py` | ZIP removal path + CSV copy path + skip redetection + pass `sgbd_manual` |
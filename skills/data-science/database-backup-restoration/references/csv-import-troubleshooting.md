# CSV Import Troubleshooting

## The Problem

The Sofia bot (`restaurar_csv()`) tries encodings in this order:
`["utf-8", "utf-8-sig", "cp1252", "latin-1"]` with `sep=None, engine="python"`.

When ALL encodings fail, the job is marked `FALHA` with:
```
Não foi possível ler o CSV com os encodings testados.
```

## Root Causes

### Delimiter is `;` not `,`
Brazilian/latin system exports often use semicolon (`;`) as the CSV delimiter.
Pandas' `sep=None` auto-detection with `engine="python"` tries to sniff the
separator, but can be confused by:
- Quoted fields containing unescaped semicolons
- Mixed quote styles
- Windows line endings (`\r\n`)

### Encoding is `latin1` / `iso-8859-1`
Many legacy systems export in Latin-1 encoding. The code tries `latin-1` (with
hyphen) as the last resort, but certain byte sequences (0x8x, 0x9x range in
Windows-1252) can still cause parsing failures.

### Quoted fields with embedded delimiters
Data like `"VP;;5;"` (semicolons inside double-quoted fields) confuses the
CSV parser even when the delimiter is detected.

## Diagnosis

### Check raw content
```bash
head -5 arquivo.csv | cat -v
```
- `^M` at end of lines → Windows line endings (usually fine)
- `;` between columns → semicolon delimiter
- High bytes like `M-e`, `M-7` → latin-1 / cp1252 encoding

### Test encodings + delimiter explicitly
```python
import pandas as pd

encodings = ["utf-8", "latin1", "cp1252", "iso-8859-1"]
for enc in encodings:
    try:
        # Try with explicit separator
        df = pd.read_csv("arquivo.csv", encoding=enc, sep=";", nrows=5, dtype=str)
        print(f"OK: {enc}, cols={list(df.columns)}, rows={len(df)}")
        break
    except Exception as e:
        try:
            # Try auto-detect
            df = pd.read_csv("arquivo.csv", encoding=enc, sep=None, engine="python", nrows=5, dtype=str)
            print(f"OK (auto-sep): {enc}, cols={list(df.columns)}, rows={len(df)}")
            break
        except Exception as e2:
            print(f"FAIL: {enc} - {e2}")
```

## Workarounds

### If the CSV uses `;` delimiter
Pre-parse the file with explicit separator before passing to the Sofia pipeline:
```python
df = pd.read_csv(arquivo, encoding="latin1", sep=";", dtype=str)
df.to_sql(tabela, engine, if_exists="replace", index=False, chunksize=1000)
```

### If a single CSV in a lote fails
1. Remove the problematic CSV from the source directory
2. Re-run the Sofia bot — it will import the remaining CSVs fresh
3. Import the problematic CSV manually into the existing database

### If partial data exists in the database
The database retains all tables imported before the failure. Verify:
```python
cursor.execute("SELECT TABLE_NAME FROM [db].INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE='BASE TABLE'")
cursor.execute("SELECT COUNT(*) FROM [db].sys.objects WHERE type='U'")
```

## Sofia Code Path

`restaurar_csv()` in `restore_engine.py`:
```python
encodings = ["utf-8", "utf-8-sig", "cp1252", "latin-1"]
df = None
for enc in encodings:
    try:
        df = pd.read_csv(caminho_csv, encoding=enc, sep=None, engine="python", dtype=str)
        break
    except Exception:
        continue

if df is None:
    return ResultadoRestauracao(
        sucesso=False,
        mensagem="Não foi possível ler o CSV com os encodings testados.",
    )
```

The shortcoming: `sep=None` with `engine="python"` is unreliable for files with
`;` delimiter and complex quoting. A fix would be to try `sep=";"` as a fallback
after the auto-detect loop fails with all encodings.

## Example: Failed `posnotas.csv` (Sophia Januacorrea)

- File: `posnotas.csv` (2.5 MB, 748 linhas, 11 colunas)
- Delimiter: `;` (semicolons)
- Encoding: `latin1` (works with explicit `sep=";"`)
- Line endings: Windows (`\r\n`)
- Content: `CODIGO_ESCOLA;ANO;DEFINICAO;PROGRAMA;ETAPA;CAB_DET_TOT;POSICAO;CAMPO;DA_ETAPA;TAMANHO;FORMATO`
- Quoted data: `"VP;;5;"` (semicolons inside quoted fields)
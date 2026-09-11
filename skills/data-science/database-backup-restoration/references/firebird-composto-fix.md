# Firebird COMPOSTO Branch Fix in restore_engine.py

## Problem

When a zipped/compressed archive contains a Firebird `.fdb`/`.gdb` file,
`format_detector.py` correctly identifies it as `COMPOSTO` with
`sgbd="firebird"`, but `restore_engine.py`'s `RestoreEngine.restaurar()` method
(in the `elif formato.formato_primario == FormatoBackup.COMPOSTO:` branch) only
has handlers for `sqlserver`, `mysql`, and `postgresql`. The `firebird` case
falls through to the `else:` clause, returning:

> "Formato composto não pôde ser identificado após extração."

## Root cause

The elif chain at `restore_engine.py:~1220` (after the patch, ~1256 lines total)
didn't include a `firebird` clause. The existing `self.restaurar_firebird()`
method (line 1061) already handles the full pipeline:

1. Detects ODS → chooses container (fb15/fb25/fb30/fb40)
2. Copies `.fdb`/`.gdb` to `docker/firebird-legado/data/<job_id>/`
3. Spins up the appropriate Firebird Docker container
4. Runs `dump-dados.sh` to extract schema + data as CSVs
5. Imports CSVs into SQL Server via `restaurar_csv_lote()`

But it was never called from the COMPOSTO branch.

## Patch applied to `migbot/core/restore_engine.py`

Add these lines before the `else:` clause inside the `COMPOSTO` branch:

```python
            elif formato.sgbd == "firebird":
                arquivos_internos = formato.arquivos_internos
                if arquivos_internos:
                    resultado = self.restaurar_firebird(arquivos_internos[0], nome_banco)
                else:
                    resultado = ResultadoRestauracao(
                        sucesso=False, sgbd="firebird", nome_banco=nome_banco,
                        mensagem="Arquivo Firebird não encontrado após extração do ZIP.",
                    )
```

**Prerequisites for the fix to work:**

- `firebird_format` module already imported at top of `restore_engine.py`
  (line 62: `from migbot.core.formats import txt_format, postgres_dump_dir, firebird_format`)
- `docker/firebird-legado/` harness must exist with `docker-compose.yml` and `dump-dados.sh`
- Docker must be available via `sg docker -c "..."`

## Verification

After the patch, a Firebird backup inside a `.zip` should flow:

```
format_detector.detectar_formato_pasta()
  → zip detected, extracted
  → inner .fdb detected as FIREBIRD_DATABASE
  → resultado.sgbd = "firebird"
  → resultado.formato_primario = COMPOSTO

restore_engine.restaurar()
  → COMPOSTO branch → sgbd == "firebird" matched
  → self.restaurar_firebird(arquivos_internos[0], nome_banco)
  → fdb copied → container spun up → dump-dados.sh → CSVs extracted
  → CSV_LOTE import into SQL Server → success
```
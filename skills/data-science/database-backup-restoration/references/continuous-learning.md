# Continuous Learning — Learn Engine Reference

## Overview

The Learn Engine (`migbot/core/learn_engine.py`) is a SQLite-backed knowledge base
that lets workers learn from each other. It stores format patterns, SGBD preferences,
encoding choices, and error-solution mappings. Workers consult before starting and
register after completing, creating a continuous improvement cycle.

## Schema (4 tables, SQLite at `migbot/conhecimento_backups.db`)

### `padroes_erro`
Recognized error patterns and their solutions.

| Column | Type | Description |
|--------|------|-------------|
| `padrao_nome` | TEXT | File/archive name pattern |
| `padrao_mensagem` | TEXT | Sanitized error message (paths/hashes redacted) |
| `solucao_tipo` | TEXT | `sgbd_fallback`, `encoding`, `formato`, `senha`, `container`, `ignorar` |
| `solucao_valor` | TEXT | The value that worked (e.g. `mysql`, `cp1252`) |
| `confianca` | REAL | 0–10, increased on success, decreased on failure |
| `total_acertos` / `total_tentativas` | INTEGER | Ratio tracks reliability |

### `encoding_preferencial`
Per-client CSV encoding + delimiter preferences.

| Column | Type | Description |
|--------|------|-------------|
| `cliente` | TEXT | Extracted client name (e.g. `magnus`, `teste_4`) |
| `encoding` | TEXT | e.g. `utf-8`, `cp1252`, `latin-1` |
| `delimiter` | TEXT | Separator character or `auto` |
| `confianca` | REAL | Confidence score |

### `sgbd_preferido`
Per-client + format SGBD preference.

| Column | Type | Description |
|--------|------|-------------|
| `cliente` | TEXT | Client name |
| `formato` | TEXT | e.g. `csv_lote`, `bak`, `compressed` |
| `sgbd` | TEXT | `sqlserver`, `mysql`, `postgresql` |
| `confianca` | REAL | Confidence score |

### `formato_conhecido`
Known file/archive → format mapping.

| Column | Type | Description |
|--------|------|-------------|
| `nome_arquivo` | TEXT | Filename or archive name |
| `formato_primario` | TEXT | e.g. `CSV_LOTE`, `MYSQL_SQL` |
| `sgbd` | TEXT | Associated SGBD |
| `precisa_senha` | INTEGER | Boolean: password-protected archive |

## Integration Points

### 1. `migbot/migbot_bot.py` — SofiaBot/MigbotBot

**Global instance:** `conhecimento = BancoConhecimento()` (line ~82)

**Consultation** (Etapa 0.5, after copy-to-staging):
```python
cliente = conhecimento.extrair_cliente(nome_arquivo)
formato_conhecido = conhecimento.consultar_formato(nome_arquivo)
sgbd_preferido = conhecimento.consultar_sgbd(cliente, "csv_lote")
```
Logs `[LEARN]` entries when knowledge is found.

**Registration** (Etapa 6, after notification):
```python
self._registrar_aprendizado(job_id, nome_arquivo, resultado, cliente, formato)
```
Registers:
- Format known → `registrar_formato(nome, formato, sgbd, acertou=resultado.sucesso)`
- Success → `registrar_sgbd(cliente, formato, sgbd, acertou=True)`
- Fallback → `registrar_padrao_erro(... solucao_tipo="sgbd_fallback", ...)`
- Failure → `registrar_padrao_erro(... solucao_tipo="desconhecido", ...)`

**Best-effort:** All wrapped in `try/except` — learning failure never breaks the job.

### 2. `migbot/core/restore_engine.py` — RestoreEngine

**Global instance:** `_conhecimento_engine = BancoConhecimento()` (module-level)

**CSV encoding optimization** (in `restaurar_csv()`):
- Before trying encodings, queries `consultar_encoding(cliente_csv)`
- Prioritizes known encodings ahead of the default `["utf-8", "utf-8-sig", "cp1252", "latin-1"]`
- On success, calls `registrar_encoding(cliente, enc, acertou=True)`

This means: if client X always uses `cp1252`, the second import skips `utf-8` and tries `cp1252` first.

## CLI Commands

```bash
PYTHONPATH=/home/hermes/conversor-backups python3 -m migbot.core.learn_engine help
PYTHONPATH=/home/hermes/conversor-backups python3 -m migbot.core.learn_engine relatorio
PYTHONPATH=/home/hermes/conversor-backups python3 -m migbot.core.learn_engine padroes
PYTHONPATH=/home/hermes/conversor-backups python3 -m migbot.core.learn_engine encoding <cliente>
PYTHONPATH=/home/hermes/conversor-backups python3 -m migbot.core.learn_engine consultar <nome_arquivo>
PYTHONPATH=/home/hermes/conversor-backups python3 -m migbot.core.learn_engine aprender <dir_jobs>
```

## Seeding from History

The `aprender_de_jobs_antigos()` method scans old job JSON files and extracts
patterns:
- CONCLUIDO + sgbd → `registrar_sgbd` + `registrar_formato`
- FALHA "formato composto não identificado" → padrao_erro "CSV_LOTE"
- FALHA "Falha ao importar ... CSV" → padrao_erro "encoding"
- Fallback bem-sucedido → padrao_erro "sgbd_fallback"

Initial seed from ~89 historical jobs produced 54 patterns (7 error patterns, 
4 encodings, 25 SGBD preferences, 26 format recognitions).
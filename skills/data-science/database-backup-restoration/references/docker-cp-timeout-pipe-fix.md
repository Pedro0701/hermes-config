# docker cp Timeout — Large-File Pipe Fix

## Reproduction

**File:** `dimensaonova.tar.gz` (998 MB compressed → 12 GB uncompressed SQL)
**Container:** `mysql_migrados` (MySQL 8.0 via Docker)
**Symptom:** `docker cp` command timed out at 120 seconds copying a 12 GB file.

### Job log (before fix)

```
[2026-07-21 10:16:41] Copiando dump para o container...
Job: 72f97e58988b496aa9f718b5f0d0fcdd
Status: FALHA
Mensagem: Erro ao importar no MySQL: Command '['docker', 'cp', '/.../um_novadimensao.sql.gz.apenas_tabelas', 'mysql_migrados:/tmp/import_...']' timed out after 120 seconds
```

### Job log (after fix)

```
[2026-07-21 10:25:17] Copiando dump para o container...
[DOCKER] Arquivo grande (11931 MB) — usando pipe em vez de docker cp...
[DOCKER] Pipe concluído.
```

## Root Cause

`docker_manager.py` `copiar_para_container()` used `docker cp` with a hard 120s timeout. For files >~10 GB, 120s is not enough — `docker cp` wraps files in a tar stream, adding overhead. The skill already recommended pipe (`docker exec -i ... cat >`) for >1 GB files, but the code didn't implement it.

## Fix Applied

File: `sofia/core/docker_manager.py`

```python
PIPE_THRESHOLD_BYTES = 1_000_000_000  # 1 GB
DOCKER_CP_TIMEOUT = 600               # 10 min

def copiar_para_container(container, caminho_local, caminho_destino):
    local_path = Path(caminho_local)
    tamanho = local_path.stat().st_size if local_path.is_file() else 0

    if local_path.is_file() and tamanho > PIPE_THRESHOLD_BYTES:
        # Pipe via stdin for large files — much faster than docker cp
        with open(caminho_local, "rb") as f:
            subprocess.run(
                ["docker", "exec", "-i", container, "sh", "-c",
                 f"cat > {caminho_destino}"],
                stdin=f, check=True, capture_output=True, timeout=DOCKER_CP_TIMEOUT,
            )
    else:
        subprocess.run(
            ["docker", "cp", caminho_local, f"{container}:{caminho_destino}"],
            check=True, capture_output=True, text=True, timeout=DOCKER_CP_TIMEOUT,
        )
```

Imports added: `import shutil`

## Why pipe beats docker cp for large files

- `docker cp` wraps the file in a temporary tar archive before streaming — this doubles the work for single large files.
- Pipe via stdin (`docker exec -i ... cat >`) streams raw bytes directly, no intermediate tar layer.
- The time difference grows with file size: for a 12 GB file, pipe finishes before `docker cp` would hit the 120s timeout.

## Reprocessing after a docker-cp timeout failure

When `docker cp` times out mid-transfer:
1. The job status is `FALHA` (not `CONCLUIDO`)
2. The dedup registry allows reprocessing (only `CONCLUIDO` blocks)
3. The staging is cleaned automatically (`[2026-07-21 10:18:44] Staging limpo.`)
4. Simply re-run the Sofia bot with the same command — the hash is the same but the `FALHA` status permits retry

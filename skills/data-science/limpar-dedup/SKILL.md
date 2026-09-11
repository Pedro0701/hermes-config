---
name: limpar-dedup
description: "Limpa por completo os registros de dedup do Migbot (MCP + watchdog + learn_engine + staging + kanban + locks) para permitir reprocessamento limpo de backups."
version: 2.0.0
author: Hermes Agent
license: MIT
---

# Limpeza Completa do Dedup

## Quando usar

- Usuário subiu novos backups de teste e quer reprocessar do zero
- Dedup está poluído com entradas FALHA / CONCLUIDO de sessões anteriores
- Learn_engine acumulou padrões obsoletos
- Staging tem pastas de jobs antigos com permissão root
- Watchdog locks (`data/staging/.watchdog_locks/`) impedem criação de novas tasks kanban mesmo com dedup limpo

## Pré-requisitos

- Acesso ao terminal no diretório do projeto (`/home/hermes/conversor-backups`)
- Acesso às tools MCP do Migbot
- Docker rodando (para limpeza de staging com permissão root)

## Passos

### 1. Resetar MCP dedup (via tools)

Liste e resete cada backup registrado no MCP:

```python
mcp__migbot__listar_backups(limite=20)
# → para cada hash, chamar:
mcp__migbot__reset_backup(hash_ou_prefixo="<primeiros 16 chars do hash>")
```

### 2. Limpar watchdog dedup + learn_engine

```bash
cd /home/hermes/conversor-backups

python3 -c "
import sqlite3
for path in ['data/registro_backups.db', 'data/conhecimento_backups.db']:
    conn = sqlite3.connect(path)
    tables = [r[0] for r in conn.execute(\"SELECT name FROM sqlite_master WHERE type='table'\").fetchall()]
    for t in tables:
        n = conn.execute(f'DELETE FROM \"{t}\"').rowcount
        print(f'{path} → {t}: {n} registro(s) removido(s)')
    conn.commit()
    conn.close()
print('Dedup limpo!')
"
```

### 3. Limpar watchdog locks

Locks em disco impedem o watchdog de criar tasks mesmo com dedup vazio.
Remova todos os locks antigos:

```bash
rm -rf /home/hermes/conversor-backups/data/staging/.watchdog_locks/*/
```

### 4. Limpar staging (pastas com permissão root)

Use Docker Alpine para remover pastas com permissão de root:

```bash
sg docker -c "docker run --rm -v /home/hermes/conversor-backups/data/staging:/data alpine rm -rf /data/*"
```

### 5. Reiniciar MCP (opcional)

Libera locks do MCP e garante ambiente limpo:

```bash
sg docker -c "docker restart migbot_mcp"
```

### 6. Verificar resultado

```bash
# Conferir que DBs e locks estão limpos
python3 -c "
import sqlite3, os
locks = os.listdir('/home/hermes/conversor-backups/data/staging/.watchdog_locks/') if os.path.isdir('/home/hermes/conversor-backups/data/staging/.watchdog_locks/') else []
print(f'Locks: {len(locks)}')
for path in ['data/registro_backups.db', 'sistemas_migrados/registro_backups.db', 'data/conhecimento_backups.db']:
    try:
        conn = sqlite3.connect(path)
        total = sum(conn.execute(f'SELECT COUNT(*) FROM \"{r[0]}\"').fetchone()[0] for r in conn.execute(\"SELECT name FROM sqlite_master WHERE type='table'\").fetchall())
        conn.close()
        print(f'{path}: {total} registros')
    except Exception as e:
        print(f'{path}: erro ({e})')
"
```

## Flags de segurança

- **NÃO** limpar `infra/firebird-legado/data/` — contém dumps temporários do Firebird
- **NÃO** dropar as tabelas — só deletar o conteúdo
- **NÃO** remover `data/staging/.watchdog_locks/` em si — só o conteúdo (subpastas)
- Kanban tasks concluídas (`done`) não interferem com novos processamentos

## Comando único (tudo em um)

```bash
cd /home/hermes/conversor-backups

# 1. Reset via MCP (você precisa listar os hashes primeiro)
# 2. Limpar watchdog + learn
python3 -c "
import sqlite3
for path in ['data/registro_backups.db', 'data/conhecimento_backups.db']:
    conn = sqlite3.connect(path)
    for r in conn.execute(\"SELECT name FROM sqlite_master WHERE type='table'\").fetchall():
        t = r[0]
        n = conn.execute(f'DELETE FROM \"{t}\"').rowcount
        print(f'{path}.{t}: {n}')
    conn.commit(); conn.close()
"

# 3. Limpar locks do watchdog
rm -rf data/staging/.watchdog_locks/*/

# 4. Limpar staging
sg docker -c "docker run --rm -v $PWD/data/staging:/data alpine rm -rf /data/*" 2>/dev/null

# 5. Restart MCP
sg docker -c "docker restart migbot_mcp" 2>/dev/null

echo '✅ Dedup limpo — pronto para novos backups!'
```
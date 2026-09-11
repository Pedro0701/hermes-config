# MCP-Only Architecture

## Decision

**Restaurações devem rodar EXCLUSIVAMENTE dentro do container `migbot_mcp`, via MCP tools.**  
O `migbot_bot.py` **NUNCA** deve ser chamado diretamente no host.

## Motivação

O pipeline de restauração depende de Docker — subir containers Firebird, executar `docker compose`, fazer bind-mounts. Quando o bot roda direto no **host** (`sg docker -c`), enfrenta:

| Problema | Host | Container (MCP) |
|----------|------|-----------------|
| Grupo docker | Precisa de `sg docker -c` | `docker` direto (uid=0) |
| `docker compose` plugin | Disponível | Precisa instalar manualmente |
| Bind-mount paths | `/app/...` não existe no host | `REPO_HOST_PATH` resolve |
| Compose `-f` flag | Funciona | Plugin ausente → erro |
| `_subir_servico()` | Recria container toda vez | Checa health antes |

## Fluxo correto

```
Backup no Drive
    │
    ▼ (watchdog)
Kanban task
    │
    ▼ (worker, ~30-50K tokens)
Worker baixa backup para data/staging/pendentes/
    │
    ▼ (chama tool MCP `restore_backup`)
Container migbot_mcp processa:
    ├── detecta formato
    ├── descompacta se necessário
    ├── Firebird → ODS → CSV → SQL Server
    ├── MySQL/PG → migrate to SQL Server
    ├── registra dedup + learn_engine
    └── retorna credenciais
    │
    ▼
Worker move resultado/exportação no Drive
```

## Ferramentas MCP (container HTTP, porta 8901)

| Tool | Função |
|------|--------|
| `health()` | Estado do servidor + bancos |
| `list_backups_on_drive()` | Consulta pendentes no Drive |
| `restore_backup(caminho, sgbd, senha)` | Pipeline completo |
| `reset_backup(hash_ou_prefixo)` | Libera dedup p/ reprocessamento |
| `verificar_backup(nome)` | Consulta dedup |
| `listar_backups()` | Últimos backups registrados |
| `move_to_resultado(nome, prefixo)` | Mover p/ Resultado/ no Drive |

## Setup do container MCP

```bash
cd /home/hermes/conversor-backups
cp infra/.env.example infra/.env  # preencher senhas
sg docker -c "docker compose -f infra/docker-compose.yml up -d"
```

Após todo restart do `migbot_mcp`, reinstalar o `docker compose` plugin:

```bash
sg docker -c "docker exec migbot_mcp bash -c '
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -sL https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-x86_64 \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
'"
```
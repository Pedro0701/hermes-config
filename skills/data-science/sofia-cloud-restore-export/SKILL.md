---
name: migbot-cloud-restore-export
description: "Restaura backups do Google Drive via MCP + exportação ActiveSoft + upload dos CSVs de volta ao Drive. Fluxo completo: rclone download → MCP restore_backup → export_engine → rclone upload."
version: 3.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [migbot, restore, export, active-soft, google-drive, rclone, sql-server, mysql, csv]
    related_skills: [database-backup-restoration]
---

# Migbot Cloud Restore + Export

## ⚠️ REGRA: MCP é a ÚNICA via de restauração

**NUNCA execute `migbot_bot.py` diretamente no host.** O pipeline de restauração roda EXCLUSIVAMENTE dentro do container `migbot_mcp` via MCP. Chamar o bot direto no host causa falhas por diferenças de ambiente (grupo docker, paths de bind-mount, compose plugin, etc.).

Sempre use as ferramentas MCP:
- `restore_backup(caminho, sgbd, senha)` — pipeline completo de restauração
- `list_backups_on_drive()` — consulta backups pendentes no Drive
- `move_to_resultado(nome, prefixo)` — mover backup processado para Resultado/
- `health()` — verificar estado do servidor e bancos
- `verificar_backup(nome)` — consultar dedup

---

## Fluxo completo (via MCP)

### Passo 1 — Listar backups pendentes

Use a tool MCP **`list_backups_on_drive()`**. Retorna lista de pastas/arquivos no Google Drive pendentes de processamento.

Ou manualmente:
```bash
rclone lsf "gdrive:1.Profissional/Conversor/Backup/" --format "sp" --separator "|"
```

### Passo 2 — Baixar para staging

Os backups precisam estar em `/home/hermes/conversor-backups/data/staging/pendentes/` para o MCP acessar (bind-mount em `/app/data/staging/pendentes/` no container).

```bash
mkdir -p /home/hermes/conversor-backups/data/staging/pendentes/[sistema]cliente
rclone copy "gdrive:1.Profissional/Conversor/Backup/[sistema]cliente" \
  /home/hermes/conversor-backups/data/staging/pendentes/[sistema]cliente/ --progress
```

### Passo 3 — Restaurar via MCP

Chame a tool MCP **`restore_backup`**:

```
restore_backup(caminho="[sistema]cliente", sgbd="sqlserver", senha="...")
```

**O que o MCP faz automaticamente:**
1. Detecta formato (magic bytes, extensão, conteúdo SQL)
2. Descompacta se necessário (zip/rar/7z/gz)
3. Sobe container Firebird se for .gdb/.fdb (detecta ODS)
4. Extrai dados para CSV se for Firebird
5. Importa para SQL Server (MySQL/PG viram SQL Server via migração)
6. Registra no dedup (evita reprocessamento)
7. Aprende padrões (learn_engine)
8. Retorna job_id, status, credenciais e logs

**Dicas:**
- `caminho` é relativo a `/app/data/staging/pendentes/` no container
- Para CSVs sem SGBD detectado, passar `sgbd="sqlserver"`
- Senha lida de `senha.txt` automaticamente
- Para reprocessar backup com falha: `reset_backup(hash_ou_prefixo=...)`

### Passo 4 — Verificar exportação ActiveSoft

Se o nome segue `[sistema]cliente` e o sistema está no catálogo, a exportação roda automaticamente. Se pulada (sistema não mapeado), executar manualmente:

```bash
cd /home/hermes/conversor-backups
PYTHONPATH=/home/hermes/conversor-backups python3 -m migbot.core.export_engine \
  <sistema> <cliente> --banco <nome_banco> --sgbd sqlserver --upload
```

### Passo 5 — Mover para Resultado/

Use a tool MCP **`move_to_resultado(nome="[sistema]cliente", prefixo="sucesso")`**.

---

## Credenciais de acesso

| SGBD | Host | Porta | Usuário | Senha |
|------|------|-------|---------|-------|
| SQL Server | localhost | 1433 | sa | Sofia@2024! |
| MySQL | localhost | 3307 | root | Sofia@2024! |

---

## Troubleshooting

### MCP não responde
```bash
curl -s http://localhost:8901/health
```

### Container migbot_mcp parado
```bash
sg docker -c "docker compose -f /home/hermes/conversor-backups/infra/docker-compose.yml up -d migbot-mcp"
```

### Docker compose plugin sumiu (após restart)
```bash
sg docker -c "docker exec migbot_mcp bash -c '
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -sL https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-x86_64 \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
'"
```
# MCP Server — Migbot

The project has **two** MCP server implementations. The stdio server (Variant A)
is for direct Hermes integration. The HTTP server (Variant B) runs in a container
alongside the databases.

---

## Variant A — Stdio FastMCP (direct Hermes integration)

**File:** `/home/hermes/conversor-backups/mcp_server.py` — FastMCP, stdio, 6 tools.

### Registration

```bash
hermes mcp add migbot \
  --command "python3" \
  --args "/home/hermes/conversor-backups/mcp_server.py"
```

The `PYTHONPATH` env is set in Hermes config via `env:` under the MCP server entry
(points to repo root and `sistemas_migrados/`). Runs on demand — no daemon.

### Tools (6)

| Tool | What it does |
|------|-------------|
| `restore_backup(path, sgbd_manual, senha)` | Runs `migbot_bot.py` — returns job_id, creds, status |
| `list_backups_status()` | Reads dedup DB — all processed backups |
| `reset_backup(hash_ou_prefixo)` | Removes dedup entry for reprocessing |
| `learn_report()` | Learn engine statistics + error patterns |
| `list_backups_on_drive()` | `rclone lsf` against Drive Backup/ folder |
| `move_to_resultado(nome, prefixo)` | `rclone move` Backup/ → Resultado/ with status prefix |

---

## Variant B — HTTP FastAPI + MCP (container deployment)

**File:** `/home/hermes/conversor-backups/migbot/mcp_server.py` — FastAPI + `fastapi-mcp`.

Runs as the `migbot-mcp` service in `infra/docker-compose.yml`, port 8901,
`network_mode: host`. Access Hermes-side as `http://localhost:8901/mcp`.

### Container setup

```bash
cd /home/hermes/conversor-backups
cp infra/.env.example infra/.env   # preencha SA_PASSWORD, MYSQL_ROOT_PASSWORD
sg docker -c "docker compose -f infra/docker-compose.yml up -d"
```

Dockerfile: `infra/migbot-mcp/Dockerfile` (slim Python 3.13 + ODBC + rclone + Docker CLI).

### Tools (13)

Same 13 tools as the REST endpoints (see SKILL.md table). Lock-based serialization
for `restore_backup` — concurrent calls return `OCUPADO`.

### Hermes config (to use HTTP variant instead of stdio)

```yaml
mcp_servers:
  migbot:
    transport: http
    url: "http://localhost:8901/mcp"
```

---

## Worker Usage

Either variant, a worker just calls the tool by name:

```
migbot_restore_backup(path="staging/pendentes/cliente/")
migbot_learn_report()
migbot_list_backups_on_drive()
```

The MCP prefix is `migbot_` (derived from the server name). Tools are
auto-discovered by the Hermes MCP client on startup or reconnect.
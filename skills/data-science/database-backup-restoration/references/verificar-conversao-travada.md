# Diagnóstico: Conversão Travada

Checklist para quando o usuário pergunta "verifique a conversão em andamento"
e o worker parece não estar progredindo.

## 1. Coleta inicial (rodar tudo em paralelo)

```bash
# Kanban — tasks ativas
hermes kanban list

# Containers — todos saudáveis?
sg docker -c "docker compose -f infra/docker-compose.yml ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'"

# MCP health — ok? restore_lock?
curl -s http://localhost:8901/health | python3 -m json.tool

# MCP jobs — últimos 10
curl -s "http://localhost:8901/jobs?limite=10" | python3 -m json.tool

# Staging pendentes
find data/staging/pendentes/ -maxdepth 2 -type f | head -30

# Dedup integrity
python3 -c "
import sqlite3
conn = sqlite3.connect('sistemas_migrados/registro_backups.db')
tables = conn.execute(\"SELECT name FROM sqlite_master WHERE type='table'\").fetchall()
print(f'Tabelas: {[t[0] for t in tables]}')
if tables:
    rows = conn.execute('SELECT COUNT(*) FROM registro').fetchone()
    print(f'Registros: {rows[0]}')
else:
    print('⚠️  DEDUP VAZIO')
"

# Learn engine stats
curl -s http://localhost:8901/aprendizado/relatorio | python3 -m json.tool

# Processos do worker
ps aux | grep "hermes.*kanban" | grep -v grep

# DBs no SQL Server já restaurados
sg docker -c "docker exec sqlserver_migrados /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P 'Sofia@2024!' -Q \"SELECT name, CAST(SUM(size)*8/1024 AS VARCHAR(20)) + ' MB' AS size_mb FROM sys.master_files f JOIN sys.databases d ON f.database_id = d.database_id WHERE d.name NOT IN ('master','tempdb','model','msdb') GROUP BY d.name ORDER BY d.name\""
```

## 2. Interpretação dos sinais

| Sinal | Significado | Ação |
|-------|-------------|------|
| `restore_lock: true` no health | MCP está processando (ou travado) | Verificar idade do lock `stat data/.migbot_mcp.lock/` |
| Job `RESTAURANDO` >30min | Possível travamento | Ver logs MCP `docker logs migbot_mcp --tail 30` |
| Job `EM_ANALISE` recente | Novo restore iniciado (provavelmente pelo watchdog) | Aguardar ou verificar se é duplicata |
| Dedup sem tabelas | Causa reprocessamento | Recriar schema e registrar DBs existentes |
| Worker PID vivo mas sem heartbeat >15min | Worker zumbi | Matar PID → dispatcher respawn |
| DB já existe no SQL Server | Restore anterior foi bem-sucedido | Registrar no dedup, mover para Resultado/ |

## 3. Recuperação por cenário

### Cenário A — Dedup vazio + DB já existe

```bash
# 1. Recriar schema do dedup
python3 -c "from registro_backups import RegistroBackups; RegistroBackups()"

# 2. Calcular hash do arquivo original e registrar manualmente
#    (ou simplesmente resetar o MCP lock e deixar o restore completar de novo,
#    mas isso desperdiça horas de processamento)

# 3. Liberar MCP lock
sg docker -c "docker exec migbot_mcp rm -rf /app/data/.migbot_mcp.lock"

# 4. Marcar job como concluído via MCP
#    (requer reset_backup + re-run manual)
```

### Cenário B — MCP job stuck com restore_lock: true

```bash
# 1. Verificar idade do lock
stat /home/hermes/conversor-backups/data/.migbot_mcp.lock/pid

# 2. Ver processos dentro do container
sg docker -c "docker exec migbot_mcp cat /app/data/.migbot_mcp.lock/pid"
sg docker -c "docker exec migbot_mcp ps aux 2>/dev/null || echo 'ps não disponível'"

# 3. Remover lock de dentro do container
sg docker -c "docker exec migbot_mcp rm -rf /app/data/.migbot_mcp.lock"

# 4. Resetar job
curl -X POST http://localhost:8901/backups/reset \
  -H "Content-Type: application/json" \
  -d '{"hash_ou_prefixo": "<prefixo_do_hash>"}'
```

### Cenário C — Worker kanban zumbi

```bash
# 1. Identificar PID do worker
hermes kanban show <task_id>
# procurar "spawned {'pid': NNNN}" nos events

# 2. Matar processo
kill <pid>
# ou kill -9 se resistir

# 3. Deixar dispatcher respawnar
# (gateway detecta a ausência e cria novo run automaticamente no próximo tick)
```

## 4. Regra de ouro

**Antes de reprocessar, verifique se a base já existe no SQL Server.**
Um dedup vazio não significa que o trabalho precisa ser refeito — significa
apenas que o registro foi perdido. As bases de dados nos containers sobrevivem
a restarts do MCP.
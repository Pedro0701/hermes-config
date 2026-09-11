---
name: kanban-worker-stuck
description: "Procedimento para detectar e bloquear workers travados no kanban do Migbot — quando um worker fica com heartbeat inativo, run parada, ou troubleshooting sem progresso."
version: 1.0.0
author: Hermes Agent
license: MIT
---

# Procedimento: Worker Travado no Kanban

## Quando usar

- Uma task está em `running` há muito tempo sem progresso real
- Heartbeat parou de atualizar (worker morreu silenciosamente)
- Worker está emitindo heartbeats de troubleshooting sem avançar
- O dispatcher não reclaimou a task automaticamente

## Como detectar um worker travado

### 1. Verificar heartbeat

```bash
hermes kanban show <task_id>
```

Procure por:
- **Último heartbeat** — se >10min atrás, o worker provavelmente morreu
- **Run #** — se o mesmo run está ativo há muito tempo (ex: run #27 por 1h+)
- **Heartbeat notes** — se contém "Troubleshooting", "testando", "debug" sem progresso

### 2. Verificar tempo de execução

```bash
# Verificar quanto tempo está rodando
hermes kanban show <task_id> --json | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('started_at'):
    import datetime
    started = datetime.datetime.fromisoformat(d['started_at'].replace('T', ' '))
    elapsed = datetime.datetime.now() - started
    print(f'Rodando há: {elapsed}')
print(f'Status: {d.get(\"status\")}')
print(f'Run atual: #{d.get(\"current_run_id\",\"?\")}')
"
```

Critérios para considerar **travado**:

| Sintoma | Ação |
|---------|------|
| Sem heartbeat há >10min | Worker morreu → **reclaim + block** |
| Heartbeats só "Troubleshooting" por >15min | Preso em loop → **block** |
| Run dura >1h sem nenhum resultado parcial | Suspeito → **investigar e block** |

## Como bloquear

### Bloquear manualmente

```bash
hermes kanban block <task_id> --kind needs_input \
  "Worker travado: <motivo>. Verificar logs e reprocessar via MCP."
```

### Tipos de block (kind)

| Kind | Quando usar |
|------|-------------|
| `needs_input` | Worker travado em troubleshooting, precisa intervenção |
| `capability` | Worker não tem ferramenta/ambiente necessário |
| `transient` | Falha temporária (ex: container reiniciou), pode tentar de novo |

### Reclaim + Block (worker morto)

Se o worker morreu mas a task ainda está `running`:

```bash
# Reclaim libera o lock do worker morto
hermes kanban reclaim <task_id> --reason "Worker sem heartbeat há >10min"

# Depois bloqueia para investigação
hermes kanban block <task_id> --kind needs_input \
  "Worker morreu sem conclusão. Verificar logs e reprocessar."
```

### Unblock para reprocessar

Depois de corrigir o problema:

```bash
hermes kanban unblock <task_id>
```

O dispatcher promove automaticamente para `ready` → `running`.

## Prevenção automática

O dispatcher já reclaima workers cujo PID morreu (crash detection) e
auto-bloqueia após `failure_limit` (default: 2) spawns consecutivos
com falha. Mas se o worker **não morre** — fica vivo emitindo heartbeat
mas sem progresso real — a detecção é manual.

### Checklist para investigar worker travado

```bash
# 1. Status da task
hermes kanban show <task_id>

# 2. Últimos eventos
hermes kanban log <task_id> --limit 20

# 3. Se worker morreu, reclaim
hermes kanban reclaim <task_id> --reason "Sem heartbeat"

# 4. Bloquear
hermes kanban block <task_id> --kind needs_input \
  "Worker travado sem progresso. Reprocessar via MCP."
```

## Comando único para bloqueio

```bash
TASK_ID="t_abc123"

# Diagnóstico
hermes kanban show "$TASK_ID"

# Reclaim + Block
hermes kanban reclaim "$TASK_ID" --reason "Worker sem heartbeat" 2>/dev/null
hermes kanban block "$TASK_ID" --kind needs_input \
  "Worker travado sem progresso real — verificar e reprocessar via MCP"

echo "✅ Task $TASK_ID bloqueada"
```
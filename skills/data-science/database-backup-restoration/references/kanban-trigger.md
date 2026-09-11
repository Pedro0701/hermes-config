# Kanban Trigger para Restore de Backups

## Arquitetura

Fluxo completo de detecção → task kanban → worker → notificação:

```
Google Drive Backup/
       │
       ▼ (a cada 15 min, cron no_agent=true, 0 tokens)
sofia_kanban_watchdog.sh
  ├─ rclone lsf → lista backups no Drive
  ├─ python3 sqlite3 → checa dedup registry (já importado?)
  └─ Para cada backup novo:
       ├─ Extrai [sistema]cliente do nome
       └─ hermes kanban create --skill sofia-cloud-restore-export --skill database-backup-restoration
       │
       ▼ (dispatcher no gateway, a cada 60s)
Kanban Board
  ├─ ready → assigned → running
  └─ Worker agent (sessão isolada, ~30-50K tokens)
       │
       ▼
Worker Agent
  ├─ Skills carregadas: sofia-cloud-restore-export + database-backup-restoration
  ├─ rclone download → Sofia bot restore
  ├─ export ActiveSoft → upload Drive
  └─ kanban_complete()
       │
       ▼
  Notificação Telegram
```

## Otimização de Tokens

| Estratégia | Tokens/backup | Automático? | Ideal para |
|------------|---------------|-------------|------------|
| Direto no chat principal | ~330K+ | Não | Depuração/debug |
| delegate_task | ~30-50K | Não | Restauração manual esporádica |
| Kanban + Worker | ~30-50K | Sim (dispatcher) | Operação contínua |
| Watchdog no_agent (só detecção) | 0 | Sim (cron) | Detecção headless |

**Por que kanban é mais eficiente que execução direta no chat:**
- O worker do kanban começa com sessão **fresca** (sem histórico acumulado)
- O watchdog de detecção roda com `no_agent=true` — **zero tokens de LLM**
- O dispatcher gerencia fila, retry e concorrência automaticamente

## Script Watchdog → Kanban

Localização: `/home/hermes/conversor-backups/scripts/sofia_kanban_watchdog.sh`

Também copiado para: `~/.hermes/scripts/sofia_kanban_watchdog.sh`

### O que o script faz:

1. **rclone lsf** — lista pastas no Drive (top-level, sem `-R` para evitar timeout)
2. **python3 sqlite3** — verifica dedup registry (stdlib, sem dependência externa)
3. Para cada backup **não processado**:
   - Extrai `[sistema]cliente` do nome da pasta
   - Cria kanban task com `--skill sofia-cloud-restore-export --skill database-backup-restoration`
   - Task fica `ready` → dispatcher designa → worker restaura

### Dependências

- `rclone` — no PATH (`~/bin/rclone` ou system-wide)
- `python3` — com módulo stdlib `sqlite3`
- `hermes` CLI — para `hermes kanban create`

### Instalação

```bash
# Copiar para ~/.hermes/scripts/
cp /home/hermes/conversor-backups/scripts/sofia_kanban_watchdog.sh \
  ~/.hermes/scripts/sofia_kanban_watchdog.sh
chmod +x ~/.hermes/scripts/sofia_kanban_watchdog.sh

# Registrar cron
cronjob action=create schedule="every 15m" \
  name="Sofia Kanban Watchdog" \
  script=sofia_kanban_watchdog.sh \
  no_agent=true \
  deliver=telegram
```

## Comandos Kanban Úteis

```bash
# Listar todas as tasks
hermes kanban list

# Ver detalhes de uma task (eventos, runs, heartbeat)
hermes kanban show <task_id>

# Designar task a um perfil (dispatcher pega em até 60s)
hermes kanban assign <task_id> default

# Criar task manualmente
hermes kanban create \
  "Restaurar [sophia]cliente" \
  --body 'Executar sofia-cloud-restore-export para [sophia]cliente

Projeto: /home/hermes/conversor-backups
PYTHONPATH=/home/hermes/conversor-backups

Passos:
1. Baixar com rclone copy
2. Rodar sofia_bot.py
3. Verificar export ActiveSoft
4. Confirmar upload ao Drive' \
  --skill sofia-cloud-restore-export \
  --skill database-backup-restoration \
  --max-runtime 2h
```

## Troubleshooting

### Task fica em "ready" mas não é designada
- Verificar se o gateway está rodando: `hermes gateway status`
- O dispatcher está embutido no gateway e verifica a cada 60s
- Designar manualmente: `hermes kanban assign <task_id> default`

### rclone lsf timeout com -R
- Usar sem `-R` para listar apenas top-level
- O script já usa `-R` apenas quando necessário

### sqlite3 CLI não encontrado
- O script usa `python3 -c` com o módulo stdlib `sqlite3`
- Não precisa do pacote `sqlite3` instalado

### Worker falha na restauração
- O dispatcher re-queue a task automaticamente (até `max-retries` vezes)
- Verificar logs: `hermes kanban show <task_id>` → events
- A task fica `blocked` após exceder retries máximos
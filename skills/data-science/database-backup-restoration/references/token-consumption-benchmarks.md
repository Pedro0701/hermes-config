# Token Consumption Benchmarks — Database Restore via Hermes

## Overview

O Hermes Agent consome tokens de LLM para orquestrar o fluxo de restauração
(listar, baixar, invocar scripts, verificar resultado, notificar). O script de
restauração (Sofia bot, restore_engine, etc.) roda localmente como Python —
**zero tokens de LLM** durante a restauração/exportação em si.

## Benchmarks Observados

### CSV_LOTE (~40 MB, 14-15 CSVs)

| Métrica | Consumo |
|---------|---------|
| Input tokens | ~330K |
| Output tokens | ~2.2K |
| Total tokens (c/ contexto) | ~745K |
| Tool calls | ~13 |
| Mensagens do agente | ~22 |
| Tempo total | ~2-3 min |

### Como Medir

```bash
# 1. Baseline antes de executar
hermes insights --days 1 | grep -E "Input tokens|Output tokens|Total tokens|Messages|Tool calls"

# 2. Executar o fluxo de restauração

# 3. Medir depois e calcular delta
hermes insights --days 1 | grep -E "Input tokens|Output tokens|Total tokens|Messages|Tool calls"
```

### Fatores que Aumentam o Consumo

| Fator | Impacto |
|-------|---------|
| Dumps SQL grandes (>500 MB) | + steps de monitoramento, + notificações |
| Múltiplos backups paralelos (delegate_task) | Tokens separados por subagente |
| Erros/troubleshooting | +50-100K input tokens por ciclo |
| Histórico longo da conversa | Contexto reenviado a cada turno |
| `rclone lsf -R` timeout e retry | + tool calls redundantes |

## Referência Rápida

- Output tokens (geração nova) é tipicamente 0.5-1% do input tokens (contexto)
- `hermes insights` reflete o total do dia, não apenas da sessão atual
- Para sessões curtas (< 5 min), o delta é uma boa aproximação do custo da operação
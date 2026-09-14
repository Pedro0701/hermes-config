# Incidente 2026-09-11: restore_backup síncrono travava worker e pipeline

## Quando usar esta referência

Um worker "completou" uma task de kanban sem resultado real
(`result_len: 0, summary: None`), ou um `restore_backup` ficou com
`restore_lock: true` por horas sem `job.logs` avançar, ou
`detectar_formato_pasta` recusou uma pasta com "não são .csv" mesmo tendo
um dump claramente identificável dentro. Os três eram o mesmo incidente,
raiz até o fim.

## O que aconteceu (timeline real, task `t_f2b99ba3` / job `b19d61fd`)

1. Run #37 (13:01-14:05): worker ficou 64min só emitindo heartbeat, sem
   progresso real, e crashou (PID morreu). Dispatcher reclamou
   automaticamente.
2. Run #38 (14:05-14:18, PID 2409): worker chamou `restore_backup` **antigo
   síncrono** via MCP pro dump MySQL de 12GB. A chamada HTTP nunca voltou
   dentro do turno do worker — ele desistiu e a task foi arquivada com
   `result_len: 0`. **O restore continuou rodando no servidor, órfão**,
   segurando o lock.
3. Ninguém verificou de novo até ~17:30 (checagem manual): o processo
   dentro do `migbot_mcp` estava vivo há 3h10min mas só tinha acumulado
   36s de CPU real — travado (provavelmente um subprocess/docker exec sem
   retorno), não "lento".
4. Destravado manualmente: `docker restart migbot_mcp` + limpar
   `data/.migbot_mcp.lock/` + limpar staging órfão (20GB).
5. Ao tentar de novo, um segundo problema apareceu: a pasta do backup
   (`base-um_novadimensao/`) tinha 4 arquivos (`.tar.gz`, `.sql`, 2×`.sql.gz`)
   — `detectar_formato_pasta` só reconhecia pasta 100% `.csv` ou 1 único
   compactado com senha; qualquer outra mistura caía em
   `precisa_perguntar_usuario`, mesmo havendo um `.sql` óbvio ali.

## Correções (commits, todos em `main` do repo)

| Commit | O quê |
|---|---|
| `591ff17` | `restore_backup` deixa de bloquear — devolve `job_id` em <1s, roda em background thread. Worker acompanha com `status_job(job_id)` em polling. |
| `e0c175e` | `job_manager._salvar_job` ganhou escrita atômica (`.tmp` + `os.replace`) — o polling mais frequente do item acima expôs uma corrida onde `carregar_job` lia o JSON no meio de uma escrita e estourava `JSONDecodeError`. |
| `c4eb6a7` | Watchdog interno no `migbot_mcp`: thread em background aborta job sem log novo por 30min (default), libera o lock, reinicia o processo (`restart: unless-stopped` no compose traz de volta limpo). `health().watchdog` expõe `job_ativo`/`job_parado_ha_segundos`. |
| `22981b9` | `detectar_formato_pasta` ganha um 4º padrão: pasta com um dump reconhecível solto (escolhe o maior `.sql`/`.sql.gz`/`.bak`/`.fdb` pela mesma prioridade que já existia pra conteúdo extraído de compactado) — os demais arquivos ficam de fora, registrados em log. |

## Lição pro worker (procedimento daqui pra frente)

- **Nunca trate uma chamada MCP de restauração como bloqueante.** Mesmo
  que o contrato pareça devolver o resultado final, confirme
  `status: "INICIADO"` e faça polling — não deixe o turno acabar esperando
  uma única chamada.
- **Emita heartbeat do kanban a cada poll**, não só quando há novidade —
  é o que evita a task ser marcada como travada por falta de heartbeat
  (ver skill `kanban-worker-stuck`) enquanto o job MCP ainda progride
  normalmente.
- Se `health().watchdog.job_parado_ha_segundos` estiver crescendo e
  próximo dos 1800s (30min), **não precisa intervir** — o watchdog
  interno já vai abortar e liberar sozinho. Só intervenha manualmente se
  quiser abortar mais rápido que isso.
- Pasta de backup com mais de um arquivo não é motivo pra desistir —
  desde `22981b9`, o MCP escolhe o dump principal automaticamente e avisa
  no log quais arquivos ficaram de fora. Se ainda cair em
  `precisa_perguntar_usuario`, é porque nenhum candidato reconhecido foi
  encontrado — aí sim vale investigar manualmente.

## Causa raiz que ainda falta (não corrigida)

O restore que travou 3h10min com CPU ~0 (item 3 da timeline) — a causa
exata (qual subprocess ficou esperando o quê) não foi identificada, só
contida pelo watchdog. Se acontecer de novo, seguir
`restoration-progress-monitoring.md` seção "Check process thread state"
(`/proc/1/task/*/wchan`) ANTES do watchdog abortar (ele mata o processo em
30min, então a janela de investigação é curta) — ou temporariamente subir
`MIGBOT_MCP_STALL_TIMEOUT` bem mais alto pra ganhar tempo de diagnóstico
numa próxima ocorrência.

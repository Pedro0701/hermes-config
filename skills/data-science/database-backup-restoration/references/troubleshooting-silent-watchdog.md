# Troubleshooting: Watchdog Silencioso (Backups Não Aparecem)

## Problema

O cron do watchdog roda (`cronjob list` mostra `last_status=ok`), mas nenhuma
task kanban é criada e o usuário reporta que backups foram adicionados ao Drive.

A saída do watchdog é vazia (zero-tokens, `no_agent=true`), o que é o
comportamento **correto** quando não há nada a fazer — mas aqui os backups
existem e não estão sendo detectados.

## Causa Mais Comum

**O caminho do rclone no watchdog não corresponde à estrutura real do Drive.**

O usuário pode ter renomeado pastas, mudado de conta, ou a estrutura do Drive
pode ter sido reorganizada. O watchdog continua rodando em silêncio porque
`rclone lsf` com um caminho inexistente retorna vazio (exit 0 ou directory not
found silencioso via `2>/dev/null`), e o script interpreta "0 arquivos" como
"nada a fazer".

## Diagnóstico em 3 Passos

### 1. Verificar status do cron

```bash
cronjob action=list
# Confirma que o watchdog está agendado, enabled=true, last_status=ok
```

### 2. Verificar se o caminho do Drive existe

```bash
# Usa EXATAMENTE o mesmo caminho que está no script do watchdog
rclone lsf "gdrive:1.Profissional/Pasta/Backup/" --format "stp" --separator "|"
```

Se retornar `directory not found`, o caminho está errado.

### 3. Descobrir o caminho real

```bash
# Lista a raiz do Drive
rclone lsf "gdrive:" --format "stp" --separator "|"

# Navega até encontrar a pasta de backups
rclone lsf "gdrive:1.Profissional/" --format "stp" --separator "|"
rclone lsf "gdrive:1.Profissional/" -R --format "stp" --separator "|" | grep -i -E "(backup|restore|resultado|export)"
```

O nome real pode ser diferente do esperado (ex.: `Sofia/` vs `Conversosr/`).

## Correção

1. Atualizar `BACKUP_REMOTO` no script do watchdog (tanto no
   `~/.hermes/scripts/` quanto no repo `scripts/`)
2. Atualizar `RCLONE_REMOTE_EXPORTACAO` no `config.py` do projeto
3. Atualizar exemplos/documentação nos skills que referenciam o caminho antigo
4. Atualizar a memória do Hermes com o novo caminho

## Prevenção

Sempre que for adicionar backups ao Drive, verificar com `rclone lsf` que o
caminho existe ANTES de esperar o watchdog detectar. Isso evita o ciclo:
"adicionei → watchdog não pegou → debug → descobri que o caminho mudou".

## Comando Útil: Listar com Detalhes

```bash
rclone lsf "gdrive:1.Profissional/<pasta>/" --format "stp" --separator "|" -R
```

O formato `stp` retorna: `tamanho|data_modificação|nome`.
Pastas têm tamanho `-1`. Use `-R` para recursivo.
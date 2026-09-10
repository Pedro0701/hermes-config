#!/usr/bin/env bash
# Migbot → Kanban Watchdog
# Detecta novos backups no Google Drive e cria tasks no kanban
# Uso: cron no_agent=true, roda em silêncio se nada novo
#
# Dependências: rclone, python3 (stdlib sqlite3), hermes CLI

set -euo pipefail

# --- Config ---
PROJETO="/home/hermes/conversor-backups"
REGISTRO_DB="$PROJETO/sistemas_migrados/registro_backups.db"
BACKUP_REMOTO="gdrive:1.Profissional/Conversosr/Backup/"
STAGING="$PROJETO/staging/pendentes"
LOCKS_DIR="$PROJETO/staging/.watchdog_locks"
LOCK_TTL_SEGUNDOS=7200  # mesmo teto do --max-runtime da task kanban
PYTHONPATH="$PROJETO"
export PATH="$HOME/bin:$PATH"

mkdir -p "$LOCKS_DIR"

# --- Lista backups no Drive (sem -R, top-level) ---
MAPFILE=()
while IFS='|' read -r tamanho data nome; do
    nome="${nome%/}"  # remove trailing /
    [[ -z "$nome" ]] && continue
    MAPFILE+=("$nome")
done < <(rclone lsf "$BACKUP_REMOTO" --format "stp" --separator "|" 2>/dev/null)

if [[ ${#MAPFILE[@]} -eq 0 ]]; then
    exit 0  # silêncio — nada a fazer
fi

# --- Verifica quais já foram processados (via python3 sqlite3 stdlib) ---
# CONCLUIDO e EM_ANDAMENTO contam como "já tratado": sem checar EM_ANDAMENTO,
# todo tick do watchdog durante um restore longo recriava a mesma task.
NOVOS=()
for nome in "${MAPFILE[@]}"; do
    ja_processado=$(python3 -c "
import sqlite3, sys
db = sqlite3.connect('$REGISTRO_DB')
count = db.execute(
    \"SELECT COUNT(*) FROM backups_importados WHERE nome_arquivo LIKE ? AND status IN ('CONCLUIDO', 'EM_ANDAMENTO')\",
    ('%$nome%',)
).fetchone()[0]
db.close()
sys.exit(0 if count == 0 else 1)
" 2>/dev/null && echo "0" || echo "1")
    [[ "$ja_processado" != "0" ]] && continue

    # Ainda existe a janela entre "task criada no kanban" e o worker chamar
    # marcar_em_andamento() (dispatcher demora até 60s) — nada no banco cobre
    # esse intervalo. Um lock em disco (mkdir é atômico) fecha essa janela,
    # inclusive entre ticks do cron rodando quase ao mesmo tempo.
    lock_nome=$(echo "$nome" | tr -c 'A-Za-z0-9_.-' '_')
    lock_path="$LOCKS_DIR/$lock_nome"
    if [[ -d "$lock_path" ]]; then
        lock_idade=$(( $(date +%s) - $(stat -c %Y "$lock_path") ))
        if (( lock_idade > LOCK_TTL_SEGUNDOS )); then
            rmdir "$lock_path" 2>/dev/null || true
        fi
    fi
    mkdir "$lock_path" 2>/dev/null && NOVOS+=("$nome")
done

if [[ ${#NOVOS[@]} -eq 0 ]]; then
    exit 0  # silêncio — nada novo
fi

# --- Cria uma task kanban para cada backup novo ---
for nome in "${NOVOS[@]}"; do
    echo "📦 Novo backup detectado: $nome"
    echo "   Criando kanban task..."

    # Extrai sistema se tiver padrão [sistema]cliente
    sistema=""
    cliente="$nome"
    if [[ "$nome" =~ \[([^\]]+)\](.+) ]]; then
        sistema="${BASH_REMATCH[1]}"
        cliente="${BASH_REMATCH[2]}"
    fi

    titulo="Restaurar $nome"
    corpo="Executar migbot-cloud-restore-export para $nome
Backup detectado em: $BACKUP_REMOTO$nome/
Projeto: $PROJETO
PYTHONPATH=$PYTHONPATH

Skills carregadas automaticamente:
- migbot-cloud-restore-export (fluxo completo)
- database-backup-restoration (pitfalls, dedup, docker)

Passos:
1. Baixar com rclone copy para $STAGING/$nome/
2. Rodar migbot_bot.py no diretório
3. Verificar export ActiveSoft
4. Confirmar upload ao Drive
5. Mover para Resultado/ no Drive"

    hermes kanban create \
        "$titulo" \
        --body "$corpo" \
        --skill migbot-cloud-restore-export \
        --skill database-backup-restoration \
        --assignee default \
        --priority 1 \
        --max-runtime 2h 2>&1

    echo "   ✅ Task kanban criada para $nome"
    echo "   ⏳ O dispatcher designará a um worker em até 60s"
done
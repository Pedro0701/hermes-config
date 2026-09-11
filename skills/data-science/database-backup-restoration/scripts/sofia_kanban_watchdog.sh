#!/usr/bin/env bash
# Sofia → Kanban Watchdog
# Detecta novos backups no Google Drive e cria tasks no kanban
# Uso: cron no_agent=true, roda em silêncio se nada novo
#
# Dependências: rclone, python3 (stdlib sqlite3), hermes CLI

set -euo pipefail

# --- Config ---
PROJETO="/home/hermes/conversor-backups"
REGISTRO_DB="$PROJETO/sistemas_migrados/registro_backups.db"
BACKUP_REMOTO="gdrive:1.Profissional/Sofia/Backup/"
STAGING="$PROJETO/staging/pendentes"
PYTHONPATH="$PROJETO"
export PATH="$HOME/bin:$PATH"

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
NOVOS=()
for nome in "${MAPFILE[@]}"; do
    ja_processado=$(python3 -c "
import sqlite3, sys
db = sqlite3.connect('$REGISTRO_DB')
count = db.execute(
    \"SELECT COUNT(*) FROM backups_importados WHERE nome_arquivo LIKE ? AND status = 'CONCLUIDO'\",
    ('%$nome%',)
).fetchone()[0]
db.close()
sys.exit(0 if count == 0 else 1)
" 2>/dev/null && echo "0" || echo "1")
    if [[ "$ja_processado" == "0" ]]; then
        NOVOS+=("$nome")
    fi
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
    corpo="Executar sofia-cloud-restore-export para $nome
Backup detectado em: $BACKUP_REMOTO$nome/
Projeto: $PROJETO
PYTHONPATH=$PYTHONPATH

Skills carregadas automaticamente:
- sofia-cloud-restore-export (fluxo completo)
- database-backup-restoration (pitfalls, dedup, docker)

Passos:
1. Baixar com rclone copy para $STAGING/$nome/
2. Rodar sofia_bot.py no diretório
3. Verificar export ActiveSoft
4. Confirmar upload ao Drive
5. Mover para Resultado/ no Drive"

    hermes kanban create \
        "$titulo" \
        --body "$corpo" \
        --skill sofia-cloud-restore-export \
        --skill database-backup-restoration \
        --assignee default \
        --priority 1 \
        --max-runtime 2h 2>&1

    echo "   ✅ Task kanban criada para $nome"
    echo "   ⏳ O dispatcher designará a um worker em até 60s"
done
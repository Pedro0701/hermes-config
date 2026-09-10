#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# sync.sh — Sincroniza configuração do Hermes com o repositório
# ──────────────────────────────────────────────────────────────────────────────
# Uso:
#   bash sync.sh push     → Copia de ~/.hermes/ para ~/hermes-config/ e commita
#   bash sync.sh pull     → Restaura de ~/hermes-config/ para ~/.hermes/
#   bash sync.sh status   → Mostra diferenças entre .hermes e o repo
#
# Arquivos versionados (SEGUROS para versionar):
#   config.yaml, SOUL.md, skills/, cron/jobs.json, scripts/, memories/
#   kanban/kanban.db
#
# Arquivos NUNCA versionados (secrets + runtime):
#   .env, auth.json, state.db, logs/, cache/, etc.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERMES_SRC="$HOME/.hermes"
REPO_DIR="$HOME/hermes-config"
REMOTE="origin"
BRANCH="main"

# ── Help ────────────────────────────────────────────────────────────────────
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | grep -v '^# --'
    exit 0
fi

# ── Função: copia de .hermes → repo ──────────────────────────────────────────
sync_push() {
    echo "📤 Sincronizando Hermes → repositório..."
    mkdir -p "$REPO_DIR"/{skills,cron,scripts,memories,kanban}

    # Config principal
    cp "$HERMES_SRC/config.yaml" "$REPO_DIR/config.yaml"
    [ -f "$HERMES_SRC/SOUL.md" ] && cp "$HERMES_SRC/SOUL.md" "$REPO_DIR/SOUL.md"

    # Skills (apenas as personalizadas, não as bundled)
    rsync -a --delete "$HERMES_SRC/skills/" "$REPO_DIR/skills/" \
        --exclude='.usage.json' \
        --exclude='node_modules/' \
        --exclude='__pycache__/' 2>/dev/null

    # Cron
    cp "$HERMES_SRC/cron/jobs.json" "$REPO_DIR/cron/jobs.json" 2>/dev/null || true

    # Scripts
    rsync -a "$HERMES_SRC/scripts/" "$REPO_DIR/scripts/" 2>/dev/null

    # Memórias
    rsync -a "$HERMES_SRC/memories/" "$REPO_DIR/memories/" 2>/dev/null

    # Kanban
    cp "$HERMES_SRC/kanban.db" "$REPO_DIR/kanban/kanban.db" 2>/dev/null || true

    # .gitignore (não sobrescreve se já existe)
    [ ! -f "$REPO_DIR/.gitignore" ] && cp "$(dirname "$0")/.gitignore" "$REPO_DIR/.gitignore" 2>/dev/null || true

    # Commit + push
    cd "$REPO_DIR"
    git add -A
    if git diff --cached --quiet; then
        echo "   ✅ Nada novo para commitar."
    else
        git commit -m "📦 Sync automático em $(date '+%Y-%m-%d %H:%M')"
        git push "$REMOTE" "$BRANCH" 2>/dev/null && echo "   ✅ Push OK" || echo "   ⚠️ Push falhou (sem remote configurado?)"
    fi
    echo "   ✅ Sincronização concluída."
}

# ── Função: copia do repo → .hermes ─────────────────────────────────────────
sync_pull() {
    echo "📥 Restaurando repositório → Hermes..."
    mkdir -p "$HERMES_SRC"

    # Pull do git primeiro
    cd "$REPO_DIR"
    git pull "$REMOTE" "$BRANCH" 2>/dev/null || echo "   ⚠️ Pull falhou, usando dados locais"

    # Config
    [ -f "$REPO_DIR/config.yaml" ] && cp "$REPO_DIR/config.yaml" "$HERMES_SRC/config.yaml"
    [ -f "$REPO_DIR/SOUL.md" ] && cp "$REPO_DIR/SOUL.md" "$HERMES_SRC/SOUL.md"

    # Skills
    rsync -a "$REPO_DIR/skills/" "$HERMES_SRC/skills/" 2>/dev/null

    # Cron
    mkdir -p "$HERMES_SRC/cron"
    [ -f "$REPO_DIR/cron/jobs.json" ] && cp "$REPO_DIR/cron/jobs.json" "$HERMES_SRC/cron/jobs.json"

    # Scripts
    mkdir -p "$HERMES_SRC/scripts"
    rsync -a "$REPO_DIR/scripts/" "$HERMES_SRC/scripts/" 2>/dev/null
    chmod +x "$HERMES_SRC/scripts/"*.sh 2>/dev/null || true

    # Memórias
    mkdir -p "$HERMES_SRC/memories"
    rsync -a "$REPO_DIR/memories/" "$HERMES_SRC/memories/" 2>/dev/null

    # Kanban
    mkdir -p "$HERMES_SRC/kanban"
    [ -f "$REPO_DIR/kanban/kanban.db" ] && cp "$REPO_DIR/kanban/kanban.db" "$HERMES_SRC/kanban.db"

    echo "   ✅ Restauração concluída."
    echo "   🔄 Execute /reset no Hermes ou reinicie o gateway para carregar."
}

# ── Função: status (diff) ──────────────────────────────────────────────────
sync_status() {
    echo "📊 Status da sincronização Hermes ↔ Repositório"
    echo ""

    # Pull mais recente
    cd "$REPO_DIR"
    git fetch "$REMOTE" 2>/dev/null || true

    # Mostra diff resumido
    echo "═══ Repositório local vs Remote ═══"
    git status --short 2>/dev/null || true
    LOCAL=$(git rev-parse HEAD 2>/dev/null)
    REMOTE_HASH=$(git rev-parse "$REMOTE/$BRANCH" 2>/dev/null || echo "sem remote")
    echo "   Local:  ${LOCAL:0:12}"
    echo "   Remote: ${REMOTE_HASH:0:12}"
    if [ "$LOCAL" != "$REMOTE_HASH" ] && [ "$REMOTE_HASH" != "sem remote" ]; then
        echo "   ⚠️ Divergente! Execute: bash sync.sh push  ou  bash sync.sh pull"
    else
        echo "   ✅ Sincronizado"
    fi

    echo ""
    echo "═══ Arquivos versionados ═══"
    ls -la "$REPO_DIR/config.yaml" 2>/dev/null && echo "  config.yaml ✅" || echo "  config.yaml ❌ ausente"
    ls -la "$REPO_DIR/SOUL.md" 2>/dev/null && echo "  SOUL.md ✅" || echo "  SOUL.md ❌ ausente"
    echo "  skills/    $(find "$REPO_DIR/skills" -name 'SKILL.md' 2>/dev/null | wc -l) skills"
    echo "  cron/      $(ls "$REPO_DIR/cron/" 2>/dev/null | wc -l) arquivo(s)"
    echo "  scripts/   $(ls "$REPO_DIR/scripts/" 2>/dev/null | wc -l) arquivo(s)"
    echo "  memories/  $(ls "$REPO_DIR/memories/" 2>/dev/null | wc -l) arquivo(s)"
    echo "  kanban/    $(ls -lh "$REPO_DIR/kanban/kanban.db" 2>/dev/null | awk '{print $5}')"
}

# ── Dispatch ────────────────────────────────────────────────────────────────
case "$1" in
    push)   sync_push ;;
    pull)   sync_pull ;;
    status) sync_status ;;
    *)
        echo "Comando inválido: $1"
        echo "Use: bash sync.sh {push|pull|status}"
        exit 1
        ;;
esac
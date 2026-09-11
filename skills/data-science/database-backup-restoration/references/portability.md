# Portabilidade — Migrar Projeto entre Servidores

## Export/Import Scripts (scripts/)

### Exportar (VM atual)
```bash
bash scripts/exportar_portavel.sh /tmp/migbot_portavel.tar.gz
scp /tmp/migbot_portavel.tar.gz usuario@vps:/tmp/
```

Empacota:
- ~/.hermes/ — config.yaml, .env, skills, state.db (sessions), kanban, cron
- Docker volumes: SQL Server + MySQL + PostgreSQL (via alpine tar)
- .bak de cada banco SQL Server (compatibilidade cross-servidor)
- .env do projeto, rclone.conf, SSH keys

### Importar (VPS nova)
```bash
tar xzf migbot_portavel.tar.gz importar_portavel.sh
bash importar_portavel.sh migbot_portavel.tar.gz
```

Automatiza:
1. Instala Docker, Python, rclone, git
2. Instala Hermes Agent via curl install.sh
3. Restaura ~/.hermes/ (config, skills, .env, sessions)
4. Restaura SSH, rclone, .env do projeto
5. Clona repositorio (SSH ou HTTPS)
6. Restaura volumes Docker
7. Sobe containers via docker compose
8. Configura MCP server + cron watchdog

## Hermes-Config Repository (sync.sh)

Para backup continuo (nao apenas export manual), existe um repositorio separado
em ~/hermes-config/ (Pedro0701/hermes-config) com script sync.sh:

```bash
# Sincronizar modificacoes para o GitHub
bash ~/hermes-config/sync.sh push

# Restaurar em VM nova (depois de clonar o repo)
cd ~ && git clone git@github.com:Pedro0701/hermes-config.git
cd hermes-config && bash sync.sh pull

# Verificar estado
bash ~/hermes-config/sync.sh status
```

### Arquivos versionados
- config.yaml — configuracao principal do Hermes
- SOUL.md — identidade do agente
- skills/ — skills personalizadas
- cron/jobs.json — jobs agendados
- scripts/ — watchdogs
- memories/ — memorias persistentes
- kanban/kanban.db — board de tarefas

### .gitignore exclui
.env, auth.json, state.db, state.db-*, logs/, cache/, sessions/,
gateway_state.json, channel_directory.json, e todo runtime regeneravel.

### Fluxo recomendado
Agendar sync.sh push como cron diario:
```bash
cronjob action=create schedule="0 23 * * *" name="Hermes Config Backup" \
  script=~/hermes-config/sync.sh no_agent=true deliver=local
```
Isso garante que skills, memorias e configuracao estejam sempre no GitHub,
mesmo sem intervencao manual.

### Requisitos da VPS
- Debian/Ubuntu (apt-get)
- Acesso root (sudo)
- Docker Engine instalavel via apt
- Portas 1433, 3307, 5432 livres
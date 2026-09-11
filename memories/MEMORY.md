MigBot (conversor-backups/migbot) renamed from Sofia. Entry point: migbot/migbot_bot.py. Learn engine fully integrated (workers consult before + register after each restore). Firebird (.fdb/.gdb/.fbk) suportado via docker/firebird-legado/ (ODS→container→CSV→SQL Server). TODO backup termina convertido em SQL Server (MySQL/PostgreSQL migrados automaticamente via _migrar_*_para_sqlserver). Fluxo documentado em docs/FLUXO_PROJETO.md.
§
User wants automatic git commits and pushes to GitHub with descriptions in Portuguese whenever new features are implemented. Project: conversor-backups (git@github.com:Pedro0701/Conversor.git). Uses Sofia bot for DB restore, rclone + Google Drive, Telegram notifications, Docker.
§
Obsidian vault deve ser em ~/Documents/Obsidian Vault. O Obsidian não está instalado na VM, precisa ser baixado e extraído (sem sudo).
§
MigBot token optimization: kanban trigger (cron no_agent + worker) ~0+30-50K. Watchdog: migbot_kanban_watchdog.sh. Learn engine integrado — padrões de erro são aprendidos automaticamente.
§
Kanban tasks for MigBot restore need `--assignee default` or dispatcher ignores them. Watchdog: `migbot_kanban_watchdog.sh`. Skills: `migbot-cloud-restore-export` + `database-backup-restoration`.
§
Firebird .GDB/.FDB: ODS detectado, container fb15/fb25/fb30/fb40. ODS 10 (FB 1.5): TRIM não existe no engine, patch dump_firebird.py (SELECT col + .rstrip()). fb_inet_server crasha, extrair dump-dados.sh do host, depois MCP CSV_LOTE. Credenciais: SYSDBA/masterkey. Docker compose plugin precisa ser instalado no MCP container.
§
Hermes config versionada em ~/hermes-config/ → GitHub: Pedro0701/hermes-config (sync.sh push/pull, cron a cada 6h)
§
MCP é a ÚNICA via de restauração — nunca migbot_bot.py direto no host. Skills atualizadas (3.0.0) refletem MCP-only. Drive folder: gdrive:1.Profissional/Conversor/.
§
Skill `limpar-dedup` criada — limpa MCP + watchdog + learn_engine + staging. Carregar com skill_view(name='limpar-dedup').
§
Skills criadas: `kanban-worker-stuck` (detecta e bloqueia workers travados — heartbeat parado, troubleshooting loop, run parada) e `limpar-dedup` v2 (agora inclui limpeza de locks do watchdog).
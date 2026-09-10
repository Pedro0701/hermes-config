#!/usr/bin/env bash
# Carrega credenciais do .env para o cron (não usa docker-compose)
ENV_FILE="/home/hermes/conversor-backups/sistemas_migrados/.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi
exec python3 /home/hermes/conversor-backups/sofia/watchdog_gdrive.py "$@"

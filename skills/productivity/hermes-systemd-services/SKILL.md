---
name: hermes-systemd-services
description: "Configure Hermes Agent components (Gateway, Dashboard, proxy, etc.) as systemd user services for auto-start at boot with linger."
version: 1.0.0
author: Pedro0701
license: MIT
trigger: user asks to make hermes dashboard/gateway/proxy start at boot, or to configure a hermes service as systemd
metadata:
  hermes:
    tags: [hermes, systemd, service, boot, auto-start, linger]
    related_skills: [hermes-agent]
---

# Hermes Systemd User Services

Configurar componentes do Hermes Agent (Gateway, Dashboard, etc.) como **systemd user services** para iniciarem automaticamente no boot.

## Pré-requisitos

- Systemd com suporte a user services (`systemctl --user`)
- `Linger` habilitado para o usuário (garante que serviços sobem mesmo sem login):

```bash
sudo loginctl enable-linger $USER
```

Verificar:
```bash
loginctl show-user $USER --property=Linger
# → Linger=yes
```

## Gatilhos para uso

- Usuário pede "faz o dashboard iniciar junto com o sistema"
- Usuário pergunta como configurar auto-start para qualquer serviço do Hermes
- Precisa que um serviço Hermes sobreviva a reboot/logout sem intervenção

## Estrutura do Service

Todos os serviços Hermes usam o mesmo padrão base. Modifique a partir do service do Gateway existente.

### 1. Gateway (já instalado via `hermes gateway install`)

```ini
[Unit]
Description=Hermes Agent Gateway - Messaging Platform Integration
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=<VENV>/bin/python -m hermes_cli.main gateway run
WorkingDirectory=%h/.hermes
Environment="PATH=<VENV>/bin:<OTHER_PATHS>"
Environment="VIRTUAL_ENV=<VENV>"
Environment="HERMES_HOME=%h/.hermes"
Restart=always
RestartSec=5
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

Caminho real: `~/.config/systemd/user/hermes-gateway.service`

### 2. Dashboard

```ini
[Unit]
Description=Hermes Agent Dashboard - Web Admin Panel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=<VENV>/bin/python -m hermes_cli.main dashboard --host 127.0.0.1 --port 9119 --skip-build --no-open
WorkingDirectory=%h/.hermes
Environment="PATH=<VENV>/bin:<OTHER_PATHS>"
Environment="VIRTUAL_ENV=<VENV>"
Environment="HERMES_HOME=%h/.hermes"
Restart=always
RestartSec=5
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

**Flags obrigatórias** (para contexto não-interativo):
- `--skip-build` — usa o dist já construído em vez de rodar npm build
- `--no-open` — **CRÍTICO**: sem essa flag o serviço abre o navegador Chrome como subprocesso, gerando processos fantasma indesejados

### 3. Proxy (se aplicável)

Mesmo padrão, substituindo `ExecStart` por `... proxy`.

## Passo a passo para criar um novo service

```bash
# 1. Descobrir o venv do Hermes
VENV=$(dirname $(dirname $(which hermes)))/venv
# ou: ~/.hermes/hermes-agent/venv

# 2. Criar o arquivo .service
# (usar write_file ou terminal com heredoc)

# 3. Recarregar e ativar
systemctl --user daemon-reload
systemctl --user enable hermes-dashboard.service
systemctl --user start hermes-dashboard.service

# 4. Verificar
systemctl --user status hermes-dashboard.service --no-pager
journalctl --user -u hermes-dashboard.service -f

# 5. Testar HTTP (dashboard)
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9119/
# → 200
```

## Comandos úteis

| Ação | Comando |
|------|---------|
| Status | `systemctl --user status hermes-<componente>.service` |
| Parar | `systemctl --user stop hermes-<componente>.service` |
| Iniciar | `systemctl --user start hermes-<componente>.service` |
| Reiniciar | `systemctl --user restart hermes-<componente>.service` |
| Logs | `journalctl --user -u hermes-<componente>.service -f` |
| Desabilitar boot | `systemctl --user disable hermes-<componente>.service` |

## Pitfalls

1. **Chrome spawning**: Sempre usar `--no-open` no Dashboard. O Hermes abre o navegador por padrão, o que gera subprocessos `chrome` e `chrome_crashpad_handler` dentro do cgroup do service.

2. **npm build**: Em serviços, usar `--skip-build`. A construção da UI web requer npm e pode falhar silenciosamente em contexto headless. O dist pré-construído está em `hermes_cli/web_dist/`.

3. **Caminho do Python**: Usar o caminho absoluto do venv, não `hermes`. O launcher shell script (`~/.local/bin/hermes`) pode depender de PATH e ambiente interativo.

4. **Restart loop**: Se o serviço falhar na inicialização, `Restart=always` + `RestartSec=5` causam loop. Verificar logs primeiro: `journalctl --user -u hermes-dashboard.service -n 50 --no-pager`.

5. **Linger**: Sem `loginctl enable-linger`, os serviços param no logout. É o erro mais comum — verificar sempre.
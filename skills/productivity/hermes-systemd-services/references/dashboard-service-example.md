# Hermes Dashboard Systemd Service

Criado em: 2026-09-11
Ambiente: Linux Mint 22.3, user `hermes`

## Arquivo final

`~/.config/systemd/user/hermes-dashboard.service`

```ini
[Unit]
Description=Hermes Agent Dashboard - Web Admin Panel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/home/hermes/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main dashboard --host 127.0.0.1 --port 9119 --skip-build --no-open
WorkingDirectory=/home/hermes/.hermes
Environment="PATH=/home/hermes/.hermes/hermes-agent/venv/bin:/home/hermes/.hermes/hermes-agent/node_modules/.bin:/home/hermes/.hermes/node/bin:/home/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="VIRTUAL_ENV=/home/hermes/.hermes/hermes-agent/venv"
Environment="HERMES_HOME=/home/hermes/.hermes"
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

## Verificação

```bash
# HTTP 200?
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9119/

# Porta ocupada?
ss -tlnp | grep 9119

# Boot habilitado?
systemctl --user is-enabled hermes-dashboard.service

# Linger ativo?
loginctl show-user $USER --property=Linger
```

## Gateway (referência)

O service do Gateway (`hermes-gateway.service`) no mesmo diretório serviu de modelo. Diferenças:
- Gateway: `ExecStart=... gateway run` (sem flags especiais)
- Dashboard: `ExecStart=... dashboard --skip-build --no-open`

## Caminho do venv

`/home/hermes/.hermes/hermes-agent/venv/bin/python`

Sempre usar caminho absoluto — o launcher `~/.local/bin/hermes` é um script shell que depende de ambiente interativo.
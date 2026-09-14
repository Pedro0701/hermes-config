#!/usr/bin/env python3
"""Watchdog de worker travado no kanban do Hermes — item 2 do plano de
resiliência (ver docs/FLUXO_PROJETO.md § MCP e a skill nativa do Hermes
`kanban-worker-stuck`, que documenta este mesmo procedimento como manual).

Uso: `hermes cron create` com `--script kanban_watchdog_travado.py
--no-agent` — roda no tick do cron, 0 tokens de LLM (é código, não agente).
A skill `kanban-worker-stuck` continua valendo pra investigação manual;
isto automatiza só o caso mecânico dela: task `running` sem NENHUM evento
novo (heartbeat, log, etc.) há mais que `KANBAN_STUCK_LIMIAR_MIN` minutos —
reclaim (libera o lock do worker) + block (kind=transient, pode reprocessar).

Não decide nada sobre o CONTEÚDO do backup — só se o worker está vivo e
progredindo. Isso é ortogonal ao watchdog dentro do migbot_mcp
(migbot/mcp_server.py:_watchdog_tick) — aquele vigia o pipeline de
restauração *dentro* do container; este vigia a sessão do worker *fora*
dele, no kanban do Hermes. Um pode travar sem o outro.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time

LIMIAR_MINUTOS = int(os.environ.get("KANBAN_STUCK_LIMIAR_MIN", "20"))


def _hermes() -> str:
    """Caminho do binário hermes — no PATH (instalação normal) ou no venv
    padrão da instalação em ~/.hermes (fallback usado nesta VM)."""
    encontrado = shutil.which("hermes")
    if encontrado:
        return encontrado
    fallback = os.path.expanduser("~/.hermes/hermes-agent/venv/bin/hermes")
    if os.path.isfile(fallback):
        return fallback
    raise RuntimeError("binário 'hermes' não encontrado no PATH nem no venv padrão")


def _rodar(*args: str) -> str:
    r = subprocess.run([_hermes(), *args], capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        raise RuntimeError(f"hermes {' '.join(args)} falhou: {r.stderr.strip()[:300]}")
    return r.stdout


def main() -> int:
    tasks = json.loads(_rodar("kanban", "list", "--status", "running", "--json") or "[]")
    if not tasks:
        return 0  # nada rodando — silencioso (stdout vazio = sem alerta, --no-agent)

    agora = time.time()
    algum_travado = False

    for t in tasks:
        task_id = t.get("id")
        if not task_id:
            continue
        try:
            detalhe = json.loads(_rodar("kanban", "show", task_id, "--json"))
        except Exception as e:  # noqa: BLE001 — task individual não pode travar o resto
            print(f"[watchdog] {task_id}: falha ao consultar detalhe ({e}) — pulando")
            continue

        eventos = detalhe.get("events") or []
        if not eventos:
            continue  # sem nenhum evento ainda (recém-criada) — não é "travada"

        ultimo_evento = max(e.get("created_at", 0) for e in eventos)
        idade_min = (agora - ultimo_evento) / 60
        if idade_min < LIMIAR_MINUTOS:
            continue

        algum_travado = True
        titulo = t.get("title", "")
        motivo = (
            f"Watchdog automático (kanban_watchdog_travado.py): sem nenhum evento "
            f"novo há {idade_min:.0f}min (limiar {LIMIAR_MINUTOS}min) — worker "
            f"provavelmente travado."
        )
        print(f"[watchdog] {task_id} ({titulo}): {motivo}")

        try:
            _rodar("kanban", "reclaim", task_id, "--reason", motivo)
        except Exception as e:  # noqa: BLE001
            print(f"[watchdog] {task_id}: reclaim falhou ({e})")
        try:
            _rodar("kanban", "block", task_id, "--kind", "transient", motivo)
        except Exception as e:  # noqa: BLE001
            print(f"[watchdog] {task_id}: block falhou ({e})")

    # stdout só tem conteúdo quando algo foi feito — com --no-agent, stdout
    # vazio = execução silenciosa (sem notificação), conteúdo = entregue
    # verbatim ao canal configurado em --deliver.
    return 0 if not algum_travado else 1


if __name__ == "__main__":
    sys.exit(main())

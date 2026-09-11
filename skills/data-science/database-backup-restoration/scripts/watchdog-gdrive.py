#!/usr/bin/env python3
"""Watchdog Sofia — monitora GDrive, baixa backups e processa um por vez.

Uso (cron no_agent=True, a cada 15min):
    cronjob action=create schedule="every 15m" script=watchdog-gdrive.sh no_agent=true deliver=local

Fluxo:
  1. Lista arquivos em GDrive:Backup/ (rclone lsf --format stp, pula uploads < 10min)
  2. Filtra já processados (Resultado/ + registro dedup SHA-256)
  3. Lock file — apenas um restore por vez
  4. Notifica Telegram ANTES do download
  5. Baixa o primeiro pendente (timeout 1h) → SofiaBot restaura → move para Resultado/ com prefixo status
"""

import os, subprocess, sys, time
from datetime import datetime
from pathlib import Path

_PROJETO = Path(__file__).resolve().parent.parent.parent  # conversor-backups/
_SCRIPTS_DIR = _PROJETO / "sistemas_migrados"
sys.path.insert(0, str(_SCRIPTS_DIR))
sys.path.insert(0, str(_PROJETO))

from sofia.core.config import TELEGRAM_CHAT_ID
from sofia.sofia_bot import SofiaBot
from sofia.telegram.notifier import enviar_mensagem
from registro_backups import RegistroBackups

RCLONE_REMOTE = "gdrive:1.Profissional/Sofia"
GDRIVE_BACKUP = f"{RCLONE_REMOTE}/Backup"
GDRIVE_RESULTADO = f"{RCLONE_REMOTE}/Resultado"
WATCH_DIR = _PROJETO / "sofia" / "gdrive_watch"
LOCK_FILE = Path("/tmp/.sofia_watchdog.lock")
LOCK_TTL = 7200          # 2h — lock expirado é forçado
UPLOAD_COOLDOWN = 600    # 10min — pula uploads em andamento
DOWNLOAD_TIMEOUT = 3600  # 1h — arquivos grandes
EXT_BACKUP = {".bak",".sql",".sql.gz",".tar",".tar.gz",".gz",".zip",
              ".tgz",".rar",".7z",".dump",".bacpac",".csv"}


def rclone_list(path):
    """Lista arquivos via lsf --format stp, pulando uploads recentes (<10min)."""
    try:
        r = subprocess.run(["rclone","lsf",path,"--format","stp","--separator","|"],
                           capture_output=True, text=True, timeout=30)
        if r.returncode: print(f"[WD] rclone lsf: {r.stderr.strip()}"); return []
        agora = time.time(); out = []
        for linha in r.stdout.strip().split("\n"):
            linha = linha.strip()
            if not linha: continue
            partes = linha.split("|", 2)
            if len(partes) < 3: continue
            tam_str, mod_str, nome = partes
            if nome.endswith("/"): continue
            # Cooldown: pula arquivos com < 10min de idade
            try:
                dt = datetime.strptime(mod_str, "%Y-%m-%d %H:%M:%S")
                if agora - dt.timestamp() < UPLOAD_COOLDOWN: continue
            except ValueError: pass
            out.append({"nome": nome, "tamanho": int(tam_str) if tam_str.lstrip("-").isdigit() else 0})
        return out
    except Exception as exc:
        print(f"[WD] rclone_list: {exc}"); return []


def rclone_copy(src, dst):
    return subprocess.run(["rclone","copy",src,dst],
                          capture_output=True, text=True, timeout=DOWNLOAD_TIMEOUT).returncode == 0


def rclone_move(src, dst):
    subprocess.run(["rclone","copy",src,dst], capture_output=True, text=True, timeout=120)
    subprocess.run(["rclone","delete",src], capture_output=True, text=True, timeout=60)


def is_backup(n):
    return any(n.lower().endswith(e) for e in EXT_BACKUP)


def lock():
    import fcntl
    try:
        fd = os.open(str(LOCK_FILE), os.O_CREAT|os.O_RDWR, 0o644)
        try: fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            if time.time()-os.fstat(fd).st_atime > LOCK_TTL: fcntl.flock(fd, fcntl.LOCK_EX)
            else: os.close(fd); return False
        os.write(fd, str(os.getpid()).encode()); os.fsync(fd); return True
    except: return False


def unlock():
    try: LOCK_FILE.unlink()
    except: pass


def main():
    backups = [a for a in rclone_list(GDRIVE_BACKUP) if is_backup(a["nome"])]
    if not backups: return 0

    ja_res = {a["nome"] for a in rclone_list(GDRIVE_RESULTADO)}
    pendentes = [b for b in backups if b["nome"] not in ja_res]
    if not pendentes or not lock(): return 0

    try:
        pendentes.sort(key=lambda x: x["nome"])
        a = pendentes[0]; nome = a["nome"]; remote = f"{GDRIVE_BACKUP}/{nome}"
        reg = RegistroBackups()

        # Notifica ANTES do download
        enviar_mensagem(
            f"\U0001f504 <b>Nova restaura\u00e7\u00e3o iniciada!</b>\n\n"
            f"\U0001f4e6 Arquivo: <code>{nome}</code>\n"
            f"\U0001f4cf Tamanho: {a['tamanho']//1024//1024}MB\n\n"
            f"Baixando do Google Drive e preparando ambiente...",
            TELEGRAM_CHAT_ID)

        WATCH_DIR.mkdir(parents=True, exist_ok=True)
        if not rclone_copy(remote, str(WATCH_DIR)):
            print(f"[WD] \u274c Falha ao baixar {nome}"); return 1

        local = WATCH_DIR / nome
        if not local.exists():
            print(f"[WD] \u274c Arquivo n\u00e3o encontrado: {nome}"); return 1

        v = reg.verificar(str(local))
        if v.ja_concluido:
            rclone_move(remote, f"{GDRIVE_RESULTADO}/ja_restaurado_{nome}"); return 0
        if v.em_andamento: return 0

        print(f"[WD] \U0001f504 Restaurando {nome}...")
        job_id = SofiaBot().processar_arquivo(str(local))
        job = SofiaBot().job_manager.carregar_job(job_id)
        suf = "erro"
        if job:
            suf = {"CONCLUIDO":"sucesso","FALHA":"falha"}.get(job.status, job.status.lower())
            print(f"[WD] {'\u2705' if job.status=='CONCLUIDO' else '\u274c'} "
                  f"Job:{job_id[:12]} | {job.status} | "
                  f"SGBD:{job.sgbd or '-'} | Banco:{job.nome_banco or '-'}")

        rclone_move(remote, f"{GDRIVE_RESULTADO}/{suf}_{nome}")
        try: local.unlink(missing_ok=True)
        except: pass
        return 0
    finally: unlock()


if __name__ == "__main__":
    sys.exit(main())

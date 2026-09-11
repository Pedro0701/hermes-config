# .gitignore para Projetos de Restauração de Banco

## Regra geral

Runtime artifacts (SQLite dedup DBs, job JSONs, CSVs temporários, staging/)
NUNCA devem ser versionados. Código-fonte (scripts/) SEMPRE deve.

## Padrões atuais do Conversor/Migbot

gitignore:
backups/
.env
csv_exemplo/
migbot/teste_mapeamento/
staging/

# Runtime — staging, jobs, WAL
data/jobs/
.claude/settings.json
migbot/clientes/**/*.csv
migbot/clientes

/sofia/

# SQLite WAL/SHM/backup ignorados
*.db
*.db-shm
*.db-wal
*.db.bak

# Exceções: bancos operacionais versionados
!data/registro_backups.db
!data/conhecimento_backups.db

# Firebird runtime
docker/firebird-legado/data/

# Jobs
migbot/jobs/
sistemas_migrados/

# Python
__pycache__/
*.pyc

# Portabilidade
*.tar.gz
exportar_portavel/
!scripts/exportar_portavel.sh
!scripts/importar_portavel.sh

## Por que versionar os bancos

data/registro_backups.db (12KB) e data/conhecimento_backups.db (40KB) sao
pequenos e essenciais para:
- Portabilidade: ao clonar o repo, o historico de backups vem junto
- Colaboracao: dois workers nao disputam o mesmo backup
- Reprodutibilidade: o learn_engine carrega o conhecimento acumulado

Sem versionar, cada deploy novo comeca do zero — todos os backups parecem
novos e sao reprocessados.

## Como verificar com um repositorio temporario

Usar python3 para criar um git init temporario, copiar o .gitignore real,
criar cada artefato e rodar git status --porcelain. Exemplo:

import tempfile, subprocess, os

with tempfile.TemporaryDirectory(prefix="verify-gitignore-") as tmp:
    subprocess.run(["git", "init", tmp], capture_output=True)
    text = open("/home/hermes/conversor-backups/.gitignore").read()
    open(f"{tmp}/.gitignore", "w").write(text)
    subprocess.run(["git", "-C", tmp, "add", ".gitignore"], capture_output=True)
    subprocess.run(["git", "-C", tmp, "commit", "-m", "init"], capture_output=True)
    for path, expect_tracked in cases:
        full = os.path.join(tmp, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        if not os.path.isdir(full): open(full, "w").close()
        r = subprocess.run(["git", "-C", tmp, "status", "--porcelain", "--", path],
                          capture_output=True, text=True)
        tracked = bool(r.stdout.strip())
        assert tracked == expect_tracked
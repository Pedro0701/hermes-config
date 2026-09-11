#!/usr/bin/env python3
"""Streaming SQL filter: reads dump on stdin, writes filtered SQL (no views/triggers/functions) to stdout.
Usage: python3 filtrar_stream.py < dump.sql | mysql -uroot -pPASS dbname
"""
import re
import sys

_MARCADORES = (
    b"DROP VIEW", b"CREATE VIEW", b"CREATE ALGORITHM",
    b"DROP TRIGGER", b"CREATE TRIGGER",
    b"DROP PROCEDURE", b"CREATE PROCEDURE",
    b"DROP FUNCTION", b"CREATE FUNCTION",
    b"ALTER VIEW", b"ALTER ALGORITHM",
)
_COMENTARIO_VERSIONADO = re.compile(rb"/\*!\d+\s?|\*/")

linhas_total = 0
linhas_removidas = 0
bytes_lidos = 0
proximo_aviso = 500 * 1024 * 1024  # 500MB

for linha in sys.stdin.buffer:
    linhas_total += 1
    bytes_lidos += len(linha)
    efetiva = _COMENTARIO_VERSIONADO.sub(b'', linha).strip().upper()
    if any(efetiva.startswith(m) for m in _MARCADORES):
        linhas_removidas += 1
        continue
    sys.stdout.buffer.write(linha)
    sys.stdout.flush()
    if bytes_lidos >= proximo_aviso:
        gb = bytes_lidos / (1024**3)
        print(f"[FILTER] {gb:.1f}GB processed, {linhas_removidas} lines removed",
              flush=True, file=sys.stderr)
        proximo_aviso += 500 * 1024 * 1024

gb = bytes_lidos / (1024**3)
print(f"[FILTER] DONE: {gb:.1f}GB ({linhas_total} lines), {linhas_removidas} removed",
      file=sys.stderr)

# MySQL Post-Import Cleanup — Non-Table Objects

## Quando usar

Depois de importar um dump MySQL que acabou trazendo functions, procedures ou triggers
que não deveriam estar no banco. Útil quando:

1. O filtro pré-importação (streaming ou file-based) falhou em capturar todos os objetos
2. A importação foi feita sem filtro (ex.: reimportação após falha)
3. O dump continha objetos dentro de `DELIMITER ;;` blocks que escaparam do filtro

## Script de limpeza

```python
#!/usr/bin/env python3
"""
Clean up non-table objects (functions, procedures, triggers) from a MySQL database.
Usage: python3 cleanup_db.py DB_NAME [PASSWORD] [HOST] [PORT]
"""
import subprocess, sys

def run_mysql(db, sql, host="127.0.0.1", port=3306, passwd="Sofia@2024!"):
    cmd = (
        f'mysql -uroot -p"{passwd}" -h{host} -P{port} {db} -e "{sql}" 2>/dev/null'
    )
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
    return r.stdout

def drop_all(db, passwd, host, port):
    for obj_type, label in [("FUNCTION", "FUNCTIONS"),
                             ("PROCEDURE", "PROCEDURES"),
                             ("TRIGGER", "TRIGGERS")]:
        if obj_type == "TRIGGER":
            query = f"SELECT TRIGGER_NAME FROM information_schema.triggers WHERE trigger_schema='{db}'"
        else:
            query = f"SELECT ROUTINE_NAME FROM information_schema.routines WHERE routine_schema='{db}' AND routine_type='{obj_type}'"
        
        col = "TRIGGER_NAME" if obj_type == "TRIGGER" else "ROUTINE_NAME"
        output = run_mysql(db, query, host, port, passwd)
        
        count = 0
        for line in output.split('\n'):
            name = line.strip()
            if name and not name.startswith((col, 'Warning', 'mysql:')):
                run_mysql(db, f"DROP {obj_type} IF EXISTS `{name}`", host, port, passwd)
                count += 1
        
        print(f"Dropped {count} {label}")

if __name__ == "__main__":
    db = sys.argv[1] if len(sys.argv) > 1 else "novadimensao"
    pw = sys.argv[2] if len(sys.argv) > 2 else "Sofia@2024!"
    host = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"
    port = int(sys.argv[4]) if len(sys.argv) > 4 else 3306
    drop_all(db, pw, host, port)
```

## One-liner shell (via information_schema)

```bash
# Generate DROP statements and pipe them into MySQL
PASS="Sofia@2024!"
DB="novadimensao"
HOST="127.0.0.1"
PORT=3306

# Generate + execute in one pipeline
mysql -uroot -p"$PASS" -h$HOST -P$PORT $DB -B -e "
  SELECT CONCAT('DROP FUNCTION IF EXISTS \`', ROUTINE_NAME, '\`;')
  FROM information_schema.routines WHERE routine_schema='$DB' AND routine_type='FUNCTION';
  SELECT CONCAT('DROP PROCEDURE IF EXISTS \`', ROUTINE_NAME, '\`;')
  FROM information_schema.routines WHERE routine_schema='$DB' AND routine_type='PROCEDURE';
  SELECT CONCAT('DROP TRIGGER IF EXISTS \`', TRIGGER_NAME, '\`;')
  FROM information_schema.triggers WHERE trigger_schema='$DB';
" 2>/dev/null | tail -n +2 | grep -v '^CONCAT' | grep -v '^$' | \
  mysql -uroot -p"$PASS" -h$HOST -P$PORT $DB 2>&1

# Verify
mysql -uroot -p"$PASS" -h$HOST -P$PORT -e "
SELECT 'TABLES' AS tipo, COUNT(*) AS total FROM information_schema.tables
  WHERE table_schema='$DB' AND table_type='BASE TABLE'
UNION ALL SELECT 'FUNCTIONS', COUNT(*) FROM information_schema.routines
  WHERE routine_schema='$DB' AND routine_type='FUNCTION'
UNION ALL SELECT 'PROCEDURES', COUNT(*) FROM information_schema.routines
  WHERE routine_schema='$DB' AND routine_type='PROCEDURE'
UNION ALL SELECT 'TRIGGERS', COUNT(*) FROM information_schema.triggers
  WHERE trigger_schema='$DB';
" 2>&1
```

## Via Docker

```bash
PASS="Sofia@2024!"
DB="novadimensao"

# Generate DROP statements
docker exec mysql_migrados mysql -uroot -p"$PASS" $DB -B \
  -e "SELECT CONCAT('DROP FUNCTION IF EXISTS \`', ROUTINE_NAME, '\`;')
       FROM information_schema.routines
       WHERE routine_schema='$DB' AND routine_type='FUNCTION';
       SELECT CONCAT('DROP PROCEDURE IF EXISTS \`', ROUTINE_NAME, '\`;')
       FROM information_schema.routines
       WHERE routine_schema='$DB' AND routine_type='PROCEDURE';
       SELECT CONCAT('DROP TRIGGER IF EXISTS \`', TRIGGER_NAME, '\`;')
       FROM information_schema.triggers WHERE trigger_schema='$DB';" \
  2>/dev/null | tail -n +2 | grep -v '^CONCAT' | grep -v '^$' | \
  docker exec -i mysql_migrados mysql -uroot -p"$PASS" $DB 2>&1
```

> **⚠️ Atenção:** A linha `CONCAT(...)` gerada pelo MySQL como cabeçalho aparece como texto literal e precisa ser filtrada com `grep -v '^CONCAT'`.

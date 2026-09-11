# MySQL Static Binary Deployment (No Docker)

## When to Use

Docker is unavailable (no root/sudo access, daemon not running, or sandboxed
environment). The MySQL 8.0 static binary tarball from Oracle runs on any Linux
system without root privileges.

## Download

```bash
# ~440MB tarball
wget https://dev.mysql.com/get/Downloads/MySQL-8.0/mysql-8.0.36-linux-glibc2.28-x86_64.tar.xz
```

## Extract

```bash
mkdir -p ~/.local
tar xf mysql-8.0.36-linux-glibc2.28-x86_64.tar.xz -C ~/.local/
export PATH="$HOME/.local/mysql-8.0.36-linux-glibc2.28-x86_64/bin:$PATH"
```

## Initialize Data Directory

Use `--initialize-insecure` to skip setting a root password (avoids the
password prompt issue):

```bash
mkdir -p ~/.mysql-data/<dbname>
mysqld --initialize-insecure --datadir=~/.mysql-data/<dbname>
```

## Start mysqld as Non-Root

```bash
mysqld --datadir=~/.mysql-data/<dbname> \
       --socket=/tmp/mysql_<dbname>.sock \
       --port=3307 \
       --skip-grant-tables \
       --max_allowed_packet=1G \
       --user=hermes &
```

Key flags:
- `--skip-grant-tables` — no auth required (avoids the password problem)
- `--max_allowed_packet=1G` — essential for large INSERT dumps
- `--user=hermes` — run as the current user, not root
- `--socket` — avoids conflicting with any system MySQL

## Connect

```bash
mysql -S /tmp/mysql_<dbname>.sock -uroot
```

## Import a Dump

```bash
mysql -S /tmp/mysql_<dbname>.sock -uroot --max_allowed_packet=1G <dbname> < /path/dump.sql
```

## Import with Progress Monitoring

```bash
# Background watchdog for 30s progress updates
(
  while true; do
    sleep 30
    mysql -S /tmp/mysql_<dbname>.sock -uroot <dbname> -N -e \
      "SELECT CONCAT('Tables: ', COUNT(*), ' | Rows: ', COALESCE(SUM(TABLE_ROWS), 0))
       FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='<dbname>' AND TABLE_TYPE='BASE TABLE'"
  done
) &
WATCHDOG_PID=$!

mysql -S /tmp/mysql_<dbname>.sock -uroot --max_allowed_packet=1G <dbname> < /path/dump.sql

kill $WATCHDOG_PID 2>/dev/null
```

## Stream Filter (Pipe Through Remove Views/Functions)

For large dumps (>5GB), pipe through a streaming filter to strip views/triggers/procedures/functions WITHOUT duplicating the file on disk:

```python
# filtrar_stream.py — reads from stdin, writes filtered to stdout
import re, sys
MARCADORES = (
    b"DROP VIEW", b"CREATE VIEW", b"CREATE ALGORITHM",
    b"DROP TRIGGER", b"CREATE TRIGGER",
    b"DROP PROCEDURE", b"CREATE PROCEDURE",
    b"DROP FUNCTION", b"CREATE FUNCTION",
)
COMENTARIO = re.compile(rb"/\*!\d+\s?|\*/")

for linha in sys.stdin.buffer:
    efetiva = COMENTARIO.sub(b'', linha).strip().upper()
    if any(efetiva.startswith(m) for m in MARCADORES):
        continue
    sys.stdout.buffer.write(linha)
```

Usage:
```bash
python3 filtrar_stream.py < dump.sql | mysql -S /tmp/mysql.sock -uroot db
```

## Set Root Password (Two-Step)

MySQL initialized with `--initialize-insecure` has no root password. To set one
and enable TCP networking:

```bash
# Step 1: Start with skip-grant-tables + skip-networking (socket only)
mysqld --datadir=~/.mysql-data/<dbname> --skip-grant-tables --skip-networking &
sleep 3

# Step 2: Set password via socket
mysql -S /tmp/mysql_<dbname>.sock -uroot \
  -e "FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED BY 'MinhaSenha!';"

# Step 3: Shutdown
mysqladmin -S /tmp/mysql_<dbname>.sock -uroot -p'MinhaSenha!' shutdown

# Step 4: Restart with networking
mysqld --datadir=~/.mysql-data/<dbname> --port=3307 --max_allowed_packet=1G
```

**Important**: `--skip-grant-tables` disables networking (`skip_networking=ON`).
You MUST restart without it to get TCP access on the port.

## libaio Dependency

The MySQL tarball requires `libaio.so.1`. Modern Ubuntu ships `libaio.so.1t64`.
Create a symlink:

```bash
ln -sf /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /home/hermes/libaio.so.1
export LD_LIBRARY_PATH=/home/hermes:$LD_LIBRARY_PATH
```

## Offline Dependency Installation

When `sudo` is not available, download and extract .deb packages:

```bash
apt-get download libaio1 uidmap libsubid4 conmon crun
dpkg -x libaio1*.deb /tmp/libs/
dpkg -x uidmap*.deb /tmp/uidmap/
export PATH="/tmp/uidmap/usr/bin:$PATH"
export LD_LIBRARY_PATH="/tmp/libs/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
```

## Shutdown

```bash
mysqladmin -S /tmp/mysql_<dbname>.sock -uroot shutdown
```

## Verify

```bash
mysql -S /tmp/mysql_<dbname>.sock -uroot -N -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='<dbname>'"
```

## Cleanup

```bash
rm -rf ~/.mysql-data/<dbname>
rm -rf ~/.local/mysql-8.0.36-linux-glibc2.28-x86_64
```

## Limitations

- No replication, no clustering, no performance schema by default
- `--skip-grant-tables` means anyone with filesystem access can connect
  — use only for isolated restore environments
- Old glibc requirement: the tarball is built against glibc 2.28+
  (Ubuntu 20.04+, Debian 11+, RHEL 8+)
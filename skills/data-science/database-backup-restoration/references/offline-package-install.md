# Offline Package Installation (Without Sudo)

## Pattern

When `sudo` is unavailable (no password, no NOPASSWD entry), use
`apt-get download` + `dpkg -x` to extract `.deb` packages to a custom
directory, bypassing the need for root:

```bash
cd /tmp

# 1. Download the .deb (no root needed)
apt-get download <package-name>

# 2. Extract to a custom prefix (no root needed)
dpkg -x <package>.deb /tmp/<package>-extracted/

# 3. Use the binaries directly
export PATH="/tmp/<package>-extracted/usr/bin:$PATH"
export LD_LIBRARY_PATH="/tmp/<package>-extracted/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
```

## Limitations

- **setuid binaries don't work** — binaries extracted this way are owned
  by the unprivileged user, so setuid/setgid bits are ineffective. This
  blocks `newuidmap`/`newgidmap` (needed for Docker/Podman rootless),
  `ping`, `su`, `sudo`, etc.
- **Shared library dependencies** — you may need to download and extract
  multiple packages recursively. Use `ldd <binary>` to find missing deps.
- **No systemd integration** — services won't be installed or started.
  Run binaries directly as foreground/background processes.
- **No triggers** — `dpkg -x` skips post-install scripts entirely.

## Example: Installing Docker Dependencies

```bash
# Docker rootless needs uidmap
apt-get download uidmap
dpkg -x uidmap*.deb /tmp/uidmap/   # contains newuidmap, newgidmap, getsubids

# Docker rootless needs rootlesskit
apt-get download rootlesskit
dpkg -x rootlesskit*.deb /tmp/rootlesskit/   # contains rootlesskit binary

# Docker rootless needs slirp4netns for networking
apt-get download slirp4netns
dpkg -x slirp4netns*.deb /tmp/slirp4netns/   # contains user-mode networking

# All together:
export PATH="/tmp/uidmap/usr/bin:/tmp/rootlesskit/usr/bin:/tmp/slirp4netns/usr/bin:$PATH"
```

## Example: MySQL 8.0 Binary (Direct Download)

For MySQL, skip the .deb entirely — download the official static binary
from Oracle which bundles all dependencies:

```bash
wget https://dev.mysql.com/get/Downloads/MySQL-8.0/mysql-8.0.36-linux-glibc2.28-x86_64.tar.xz
tar xf mysql-8.0.36-linux-glibc2.28-x86_64.tar.xz
export PATH="$PWD/mysql-8.0.36-linux-glibc2.28-x86_64/bin:$PATH"
```

## Working with sudo via stdin

When you DO have the sudo password, pass it via stdin:

```bash
echo "$PASSWORD" | sudo -S apt-get install -y docker.io
```

⚠️ Be careful not to log or echo the password in error messages.
Redact it before any logging or display.
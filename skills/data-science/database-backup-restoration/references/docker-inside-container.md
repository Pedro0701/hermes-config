# Docker-from-inside-Container Pattern

When the Migbot MCP container (`migbot_mcp`) needs to run Docker commands
(restore backups, start Firebird, execute dumps inside ephemeral containers),
it faces three distinct problems because the Docker daemon runs on the *host*
while the CLI runs *inside* the container.

## Problem 1: `sg docker -c` fails as root

Inside the container, `id` shows `uid=0(root) gid=0(root) groups=0(root)` —
there is no `docker` group. The `sg docker -c "..."` wrapper used on the host
fails with `sg: no such group`.

**Solution:** Detect context with `os.geteuid() == 0`:

```python
inside = os.geteuid() == 0
if inside:
    # Direct call — root has socket access via bind-mount
    subprocess.run(["docker", "inspect", "-f", "{{.State.Health.Status}}", "fblegado_fb25"],
                   capture_output=True, text=True, timeout=10)
else:
    # Host: need sg to get group permissions
    subprocess.run(["sg", "docker", "-c",
                    "docker inspect -f '{{.State.Health.Status}}' fblegado_fb25"],
                   capture_output=True, text=True, timeout=10)
```

This pattern appears three times in `firebird_format.py`:
- `_subir_servico()` — health check + compose up
- `_executar_dump_dados()` — run dump-dados.sh
- `_derrubar_servico()` — compose down

## Problem 2: `docker compose` plugin missing

The `COPY --from=docker:27-cli` in the Dockerfile only brings the `docker`
binary — not the `docker compose` plugin (it's a separate binary installed
by Docker Desktop or the docker-compose-plugin package).

Without it, `docker compose up -d fb25` fails with `unknown shorthand flag: 'f'`.

**Solution:** Install the compose CLI plugin at container build time:

```dockerfile
COPY --from=docker:27-cli /usr/local/bin/docker /usr/local/bin/docker
RUN mkdir -p /usr/local/lib/docker/cli-plugins && \
    curl -sL "https://github.com/docker/compose/releases/download/v2.32.4/\
docker-compose-linux-$(uname -m)" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose && \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
```

## Problem 3: Bind-mount paths resolve on the host

When the container runs `docker run -v /app/data:/data ...`, the Docker daemon
interprets `/app/data` on the **host** filesystem — not inside the calling
container. Since `/app` only exists inside the `migbot_mcp` container (created
by the compose bind-mount `..:/app`), the daemon sees an empty or
nonexistent directory and creates it as empty.

**Solution — host path indirection:**

1. Pass the host-visible repo path as an env var:
   ```yaml
   # docker-compose.yml
   environment:
     REPO_HOST_PATH: "/home/hermes/conversor-backups"
   ```

2. Use dual-path variables in shell scripts:
   ```bash
   HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"       # container path
   HARNESS_DIR_HOST="${HARNESS_DIR}"                                   # host path (default)
   if [ -n "${REPO_HOST_PATH:-}" ]; then
     HARNESS_DIR_HOST="${HARNESS_DIR/#\/app/$REPO_HOST_PATH}"          # substitute /app/ → host path
   fi
   ```

3. Use `HARNESS_DIR_HOST` for **Docker volume mounts**, and `HARNESS_DIR` for
   **local file operations** (existence checks, source):
   ```bash
   # dump-dados.sh — Docker mounts use HOST path:
   docker run --rm -v "$HARNESS_DIR_HOST/data:/data" ...

   # _rel() — local existence check uses container path:
   [ -f "$DATA_DIR/$rel" ] || { echo "nao existe"; }
   ```

## Problem 4: Compose up recreates healthy containers

`docker compose up -d <service>` calls recreate (stop + start) the container
even when it's already running and healthy. This resets the healthcheck to
`starting`, causing a 2-minute wait loop that times out.

**Solution:** Check health before compose up:

```python
# Early return if container already healthy
chk = subprocess.run(
    ["docker", "inspect", "-f", "{{.State.Health.Status}}", f"fblegado_{servico}"],
    capture_output=True, text=True, timeout=10,
)
if chk.returncode == 0 and chk.stdout.strip() == "healthy":
    return True
```

## Summary

| Problem | Symptom | Fix |
|---------|---------|-----|
| sg docker fails | `sg: no such group` | `os.geteuid() == 0` dispatch |
| compose missing | `unknown shorthand flag: 'f'` | Install compose CLI plugin in Dockerfile |
| Bind-mount path | Empty target dirs in volumes | `REPO_HOST_PATH` + dual-path vars |
| Compose recreates | Healthcheck resets to `starting` | Check healthy first, skip compose up |
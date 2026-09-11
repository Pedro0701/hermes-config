# rclone Cloud Storage Setup for Backups

## Overview

When backup files live in cloud storage (Google Drive, OneDrive, etc.) and the user
cannot create a GCP project (blocked by `resourcemanager.projects.create`), rclone
is the practical alternative. It handles OAuth directly in the terminal with no
Google Cloud Console required.

## Installation (no sudo)

```bash
# Prefer apt if sudo is available
sudo apt install rclone

# Fallback: binary download from GitHub
curl -sL -o /tmp/rclone.zip \
  "https://github.com/rclone/rclone/releases/download/v1.69.2/rclone-v1.69.2-linux-amd64.zip"
unzip -q /tmp/rclone.zip -d /tmp/rclone_extract
mkdir -p ~/bin
cp /tmp/rclone_extract/rclone-*/rclone ~/bin/
chmod +x ~/bin/rclone
export PATH="$HOME/bin:$PATH"
```

## Google Drive OAuth Setup

1. Run `rclone authorize "drive"`
2. It starts a local web server at `http://127.0.0.1:53682/`
3. Tell the user to open the URL shown in the output in their browser
4. The browser redirects to Google's OAuth consent screen
5. User logs in and authorizes
6. Google redirects back to localhost → rclone captures and saves the token

The token is saved to the rclone config file (`~/.config/rclone/rclone.conf`) and
auto-refreshes as needed.

## Creating a remote

After authorization, rclone creates a remote named `drive` automatically.
If it doesn't (e.g., using `rclone authorize` separately), create it:

```bash
rclone config create drive drive scope=drive
```

## PATH persistence

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
```

## Common Commands Reference

| Goal | Command |
|------|---------|
| List folders | `rclone lsd drive:` |
| List files | `rclone ls drive:Backups-BD` |
| List with details | `rclone lsl drive:Backups-BD` |
| List file names only | `rclone lsf drive:Backups-BD` |
| Download file | `rclone copy drive:path/to/file.bak /local/dir/` |
| Sync folder | `rclone sync drive:Backups-BD /local/backups/ --progress` |
| Filter by type | `rclone copy drive:dir /local/ --include "*.{bak,sql}"` |
| Check for changes | `rclone check drive:dir /local/backups/` |
| Pipe to stdout | `rclone cat drive:path/file.sql.gz` |
| Upload back | `rclone copy /local/file.sql drive:Processados/` |

## Troubleshooting

- **"No token saved"**: The rclone authorize server was killed before the OAuth
  callback arrived. Re-run the command and ensure the browser redirect completes.
- **Rate limiting**: Google Drive has API quotas. Space out `rclone check` calls
  (at least 1 minute apart). For cron, use `rclone check` at most every 15 min.
- **Token refresh failure**: Delete `~/.config/rclone/rclone.conf` and re-authorize.
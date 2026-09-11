---
name: linux-appimage-install
description: Install Linux desktop applications via AppImage without sudo — download, desktop entry, icon extraction, and symlink setup.
platforms: [linux]
---

# Linux AppImage Install

Use this skill when installing a desktop application on Linux via AppImage without root/sudo. Covers discovering the latest version, downloading, creating desktop entries, extracting icons, and setting up convenience symlinks.

## Trigger conditions

- User asks to install a Linux app that distributes via AppImage
- User says "no sudo" or "without root"
- Binary check (`which <app>`) returns empty

## Procedure

### 1. Discover latest version URL

For GitHub-hosted releases, scrape the download page:

```bash
curl -sL "<app-download-page>" | grep -oP 'href="[^"]*AppImage[^"]*"' | head -5
```

Pick the non-arm64 (`x86_64`) URL unless the system is ARM. Use `uname -m` to confirm architecture.

### 2. Download

```bash
mkdir -p ~/.local/bin
curl -L -o ~/.local/bin/<AppName>-<version>.AppImage "<url>"
```

Expect 100-200 MB. On slow connections this can take 15-20+ minutes — use `terminal(background=true, notify_on_complete=true)`.

### 3. Make executable + symlink

```bash
chmod +x ~/.local/bin/<AppName>-<version>.AppImage
ln -sf ~/.local/bin/<AppName>-<version>.AppImage ~/.local/bin/<appname>
```

### 4. Extract icon

**Pitfall**: `--appimage-extract <filename>` only extracts a symlink for icons. Use full extraction:

```bash
cd ~/.local/bin
./<AppName>-<version>.AppImage --appimage-extract
# Icon is usually at squashfs-root/usr/share/icons/hicolor/<size>/apps/<appname>.png
find squashfs-root -name "<appname>.png" -type f
cp squashfs-root/path/to/<appname>.png ~/.local/share/icons/<appname>.png
rm -rf squashfs-root
```

### 5. Desktop entry

Create `~/.local/share/applications/<appname>.desktop`:

```desktop
[Desktop Entry]
Name=<App Display Name>
Comment=<One-line description>
Exec=/home/$USER/.local/bin/<AppName>-<version>.AppImage --no-sandbox %U
Icon=<appname>
Terminal=false
Type=Application
Categories=<categories>;
MimeType=<mime-types>;
StartupWMClass=<wm-class>
```

- `--no-sandbox` is often needed for Electron-based apps running as AppImage.
- Use `$USER` literally (the .desktop spec does not expand env vars in Exec).
- `Icon=<appname>` references `~/.local/share/icons/<appname>.png` without extension.

### 6. Update cache

```bash
update-desktop-database ~/.local/share/applications/
```

## Verification

```bash
which <appname>           # should show ~/.local/bin/<appname>
file ~/.local/bin/<AppName>-<version>.AppImage  # should be "ELF 64-bit LSB executable"
ls ~/.local/share/icons/<appname>.png            # icon exists
```

The app should now appear in the system application menu and be launchable from terminal.

## Reference: Obsidian example

See `references/obsidian-example.md` for the full session transcript of installing Obsidian v1.12.7.
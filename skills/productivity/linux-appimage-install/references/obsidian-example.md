# Obsidian AppImage Install — Session Example

Session date: 2026-07-20
System: Linux Mint (x86_64), no sudo

## Version discovery

```bash
$ curl -sL "https://obsidian.md/download" | grep -oP 'href="[^"]*AppImage[^"]*"'
href="https://github.com/obsidianmd/obsidian-releases/releases/download/v1.12.7/Obsidian-1.12.7.AppImage"
href="https://github.com/obsidianmd/obsidian-releases/releases/download/v1.12.7/Obsidian-1.12.7-arm64.AppImage"
```

Picked the x86_64 URL (not arm64).

## Download

119 MB, took ~19 minutes at ~103 KB/s.
Used background mode with notify_on_complete.

## Icon extraction pitfall

First attempt failed:
```bash
$ ./Obsidian-1.12.7.AppImage --appimage-extract obsidian.png
# Creates squashfs-root/obsidian.png -> usr/share/icons/hicolor/512x512/apps/obsidian.png (symlink!)
$ cp squashfs-root/obsidian.png ~/.local/share/icons/
# FAILS — symlink target not extracted
```

Fix: full extraction, then copy the real file:
```bash
$ ./Obsidian-1.12.7.AppImage --appimage-extract
$ find squashfs-root -name "obsidian.png" -type f
squashfs-root/usr/share/icons/hicolor/512x512/apps/obsidian.png
$ cp squashfs-root/usr/share/icons/hicolor/512x512/apps/obsidian.png ~/.local/share/icons/obsidian.png
$ rm -rf squashfs-root
```

## Desktop entry

```desktop
[Desktop Entry]
Name=Obsidian
Comment=Obsidian - A knowledge base that works on local Markdown files
Exec=/home/hermes/.local/bin/Obsidian-1.12.7.AppImage --no-sandbox %U
Icon=obsidian
Terminal=false
Type=Application
Categories=Office;Utility;
MimeType=x-scheme-handler/obsidian;
StartupWMClass=obsidian
```

## Vault

User's vault lives at `~/Documents/Obsidian Vault/` (with space in path).
The bundled `obsidian` skill handles vault operations (read, search, create, edit notes).
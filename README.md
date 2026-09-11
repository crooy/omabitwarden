# omabitwarden

Bitwarden vault panel as an Omarchy shell plugin (kind: bar-widget): a lock icon in the bar toggles the vault panel; the icon keeps the shell plugin loaded.

## Features

- Unlock with the master password through the official `bw` CLI (`bw unlock --passwordenv`, master password never on argv).
- Owns port `127.0.0.1:8087`: spawns a local `bw serve` after unlock; on lock (and at startup, if one is left over) any `bw serve` on that port is killed — a leftover serve would keep the vault open without any key.
- Search vault items by name or username; copy `username`, `password`, or TOTP — TOTP codes are computed locally in pure JS (RFC 6238), no bw subprocess per copy.
- Password and passphrase generator, straight to the clipboard.
- Clipboard secrets go via `wl-copy --sensitive` with a guarded 45s auto-clear.
- Three placement modes (bar-layout entry `settings.placement`, default `window`): `icon` = popout card under the bar icon, `centered` = popout card centered on the bar axis, `window` = two real windows — the unlock card in a small temporary floating window (float + center, never pinned) and the unlocked vault in its own larger window (separate title/state, `SUPER+T` un-floats). Persistent while open: no outside-click dismissal, copy toasts don't close; Esc closes, `SUPER+W` closes.
- Auto-locks after 15 minutes idle; the session key lives in memory only (never argv, URL, or disk).

## Install

Prerequisite: the official Bitwarden CLI (`bw`) on your `PATH` (`/usr/bin/bw`).

```
omarchy plugin add <git-url> --enable
omarchy plugin enable crooy.omabitwarden right
```

The plugin lands in `~/.config/omarchy/plugins/crooy.omabitwarden`. Instead of the `enable` command you can manually add `{"id": "crooy.omabitwarden"}` to `bar.layout.right` in `~/.config/omarchy/shell.json`.

Dev install: clone the repo and symlink it into `~/.config/omarchy/plugins/crooy.omabitwarden`.

## Usage

- Left click the bar icon: toggle the panel; right click: lock.
- If a keybind is configured (e.g. `SUPER+B` → `omarchy-shell omabitwarden toggle`), use it.
- Switch placement live: `omarchy-shell omabitwarden setPlacement window` (or `icon`/`centered`); the choice is written back to `shell.json`.

## IPC

Target `omabitwarden`:

| Method    | Effect                     |
|-----------|----------------------------|
| `toggle`  | Show/hide the vault panel  |
| `lock`    | Lock the vault             |
| `status`  | Prints `locked`/`unlocked` |
| `setPlacement <mode>` | Switch placement live: `icon`/`centered`/`window` (persists to shell.json) |
| `getPlacement` | Prints the current placement mode |

Example: `omarchy-shell omabitwarden toggle`

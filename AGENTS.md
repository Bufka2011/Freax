# AGENTS.md — Freax (OpenComputers Lua OS)

Freax is a from-scratch OpenOS-inspired OS for OpenComputers (Minecraft).
Lua 5.2-ish (OC Lua, `bit32`). No host toolchain: no `lua`/`luac`/`luacheck`,
no CI, no package manager. Verification happens **in-game** (see below).

## Layout: repo root mirrors the installed root (`/`)

- `boot/kernel/main.lua` — the kernel (~1900 lines); `init.lua` — boot entry
  (mounts VFS, hands off to kernel); `manifest` → `/manifest`
- `lib/*.lua` → `/lib/*.lua`; `bin/*.lua` → `/bin/*.lua`
- **extensionless files in `usr/man/`** are **man pages**, not code
- `etc/{motd,passwd,shadow,hostname}` → `/etc/` (hostname: local-only, not installed).
  Dev media carries live account DB so it boots into login (root, no password).
  Media without `/etc/passwd` triggers demo mode (notice + shell, no wipe).
- Root-level `selfcheck.lua` (dev smoke test) and `.gitignore` are dev-only:
  protected from the demo wipe via `manifest` but not installed.

## Adding a file? Update two lists

1. **`manifest`** — authoritative ship list. Boot without `/etc/passwd`
   (demo media) **deletes anything on the boot drive not listed here**
   (dotfiles and mount points spared). Add the repo-relative path.
2. **`bin/install.lua` `FULL` table** — one `entry("<dst>")` per shipped file
   (source path == dst by the mirror rule), else the file never reaches the
   target and verification (`need` list) may fail.

## Kernel / process rules (`boot/kernel/main.lua`)

- Processes are coroutines + private `_ENV`. Only yield points: `freax.wait`,
  `freax.pullEvent`/`pollEvent`, `ttyReadLine`, `freax.exit`, sleeps.
- No ambient hardware authority: `component` is a stub that **errors**;
  `computer` is an info-only subset (`pushSignal` denied, no `debug`/`loadstring`/`_G`/global `require`).
  Everything goes through `freax.*` syscalls or `require("fs"|"shell"|"term"|…)`.
- OC filesystem proxies use **dot-calls**: `fs.open(path)`, never `fs:open()`.
- Symlinks are a kernel RAM table (`links`), **lost on reboot**; cycles must error, never hang.
- `os.execute`/`io.popen`/`sh` resolve via `PATH` (`/bin` + `.lua` suffix probing).
- `K.start` boots `/bin/login.lua`, falling back to `/bin/sh.lua`.

## Low-RAM discipline (real hardware OOMs)

- **Stream in 4K chunks**, never `readFile` + concat a whole file
  (kernel is ~66K; kernel + shell + installer + 2 copies exceeds budget).
  See chunked loops in `bin/install.lua`.
- Keep per-char string buildup out of hot paths (`ttyWrite` segments writes).
- Install verification uses `fs.size`, not full reads, for the same reason.

## Verify in-game (nothing runs on host)

- `lua /selfcheck.lua` — dev smoke test (**not installed**; runs requires,
  thread join/order, symlink-cycle errors, `os.execute` spot checks).
  Fails write `/s_fail.txt` and exit 1.
- `install` needs a second writable HDD; tmpfs targets are skipped by design
  (use `--to=ADDR` to force, `--from=ADDR` to pin source).
- Before committing: `git status` — restore `etc/hostname` if the mock harness
  deleted it (recurring gotcha, see log). Never commit `s_*.txt`, `*.bak`,
  `dmesg_dump.txt`, `iotest.txt` (already in `.gitignore`).
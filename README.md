# FREAX - Linux-like OS for OpenComputers

Freax is a from-scratch OpenOS replacement for the OpenComputers mod
(Minecraft 1.7.10, GTNH fork). Named after the original name Linus
Torvalds rejected for Linux.

Capability-based process isolation, bash-inspired shell, FHS filesystem
layout.

## Design

- **Microkernel-ish**: coroutine processes with private `_ENV`, no
  ambient hardware authority. Processes see `component`? It errors.
  All hardware through `freax.*` syscalls.
- **Preemption by OC runtime**: the host kills scripts that run too long
  without yielding. That error unwinds through ONE coroutine - the hog
  dies, the kernel lives.
- **Shell**: bash-ish - pipes `|`, redirects `> >> < 2>` `2>&1`,
  chaining `; && ||`, vars `$VAR`, aliases, source, job control.

## Status

Milestone reached: **M4** (OpenOS feature parity + shared module runtime).

- Kernel: scheduler, process table, syscall sandbox, VFS with mounts
  (incl. read-only), pipes (8K buffer), virtual symlinks (RAM table, lost
  on reboot), parent PID tracking, graceful shutdown/reboot signalling,
  autorun, ANSI SGR parsing in `ttyWrite`, Ctrl+C foreground-tree kill,
  and a shared module runtime (each library compiles once per machine and
  dispatches to the running process).
- Shell: bash-ish tokenizer, pipelines, redirects, builtins, PATH
  resolution, history, aliases, source. Parsing/execution now lives in the
  reusable `lib/sh.lua` (builtins, `;`/`&&`/`||`/`|`, glob, redirects),
  consumed by `bin/sh.lua`.
- Filesystem: OC filesystem proxies via VFS, tmpfs mounted at `/run`,
  mounts at `/mnt/<short>` for non-boot devices, `lib/devfs.lua` mounted
  lazily at `/dev` on first access.
- Terminal: `lib/tty.lua` ANSI/VT100 stream (SGR colors, cursor
  moves/erase/save-restore, wrap toggle, scrolling, auto-flush) backed by
  `freax.*` tty syscalls.
- Installer: copies all files from source to target HDD with chunked
  4K streaming (no OOM on low-RAM hardware), verification via `fs.size`,
  account DB generation, `/home/` preservation.
- Coreutils: ls, cat, cp, mv, mkdir, rm, rmdir, touch, head, grep, wc,
  sort, du, tree, find, less, edit (touch/clipboard/Unicode/configurable
  keybinds), ln, lua repl, ps (parent tree), kill, dmesg, df,
  mount/umount (ro), free, uptime, date, time, yes, which, printenv,
  hostname, cd, pwd, set/unset, source, rc, reboot/shutdown,
  components/lshw/address/primary, flash, label, resolution, redstone,
  wget, pastebin, man, login, passwd, su, whoami, adduser, useradd,
  userdel.

## Quick start

Copy the repo files to an OC disk/diskette, preserving paths. Boot the computer.

Run `install` to install to a hard drive (needs a second writable HDD).

After that, update without leaving the game: `apt update`, `apt upgrade`,
then `reboot` when asked (needs an internet card, versioned by `/VERSION`).

## Requirements

- OpenComputers (GTNH fork, 1.7.10).
- Minimum RAM: ~384K in practice - the kernel and boot libraries dominate
  the floor (the kernel alone is ~87K of Lua).
- Recommended: a hard drive (for `install`) and an internet card (for `apt`).

## Files

- `boot/kernel/main.lua` - the kernel (~2600 lines).
- `init.lua` - boot entry point.
- `bin/*.lua` - programs and coreutils.
- `lib/*.lua` - libraries (fs, shell, term, event, auth, thread, etc.).
- `usr/man/*` - man pages (extensionless).
- `etc/` - config (motd, passwd, shadow, hostname).
- `manifest` - shipped-file list driving `install`, `apt`, and demo protection.
- `selfcheck.lua` - dev smoke test (not installed).

See AGENTS.md for detailed development conventions.

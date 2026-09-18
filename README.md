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

Milestone reached: **M2** (boot -> kernel -> VFS -> shell).

- Kernel: scheduler, process table, syscall sandbox, VFS with mounts,
  pipes (8K buffer), virtual symlinks (RAM table, lost on reboot).
- Shell: bash-ish tokenizer, pipelines, redirects, builtins, PATH
  resolution, history, aliases, job control, source.
- Filesystem: OC filesystem proxies via VFS, `/tmp` tmpfs, mounts at
  `/mnt/<short>` for non-boot devices.
- Installer: copies all files from source to target HDD with chunked
  4K streaming (no OOM on low-RAM hardware), verification via `fs.size`,
  account DB generation, `/home/` preservation.
- Coreutils: ls, cat, cp, mv, mkdir, rm, rmdir, touch, head, grep, wc,
  sort, du, tree, find, less, edit, ln, lua repl, ps, kill, dmesg, df,
  mount/umount, free, uptime, date, time, yes, which, printenv, hostname,
  reboot/shutdown, components/lshw/address/primary, flash, label,
  resolution, redstone, wget, pastebin, man, login, passwd, su, whoami,
  adduser.

## Quick start

Copy the repo files to an OC disk/diskettepreserving paths. Boot the computer.

Run `install` to install to a hard drive (needs a second writable HDD).

## Requirements

- OpenComputers (GTNH fork, 1.7.10).
- Minimum: Tier 1 computer, floppy.
- Recommended: Tier 2+ computer, HDD, internet card.

## Files

- `boot/kernel/main.lua` - the kernel (~1900 lines).
- `init.lua` - boot entry point.
- `bin/*.lua` - programs and coreutils.
- `lib/*.lua` - libraries (fs, shell, term, event, auth, thread, etc.).
- `usr/man/*` - man pages (extensionless).
- `etc/` - config (motd, passwd, shadow, hostname).
- `manifest` - shipped-file list for demo-mode protection.
- `selfcheck.lua` - dev smoke test (not installed).

See AGENTS.md for detailed development conventions.

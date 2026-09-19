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
- Package management: `apt`/`dpkg` with repositories (Debian-style
  `deb` source lines), index download and verification, dependency
  resolution, install/remove/upgrade/purge, maintainer scripts
  (`preinst`/`postinst`/`prerm`/`postrm`), and conffile handling.
  Archives use the uncompressed `.fpkg` format. `apt sysupdate` /
  `apt sysupgrade` retain the legacy manifest-based OS self-update.

## Quick start

Copy the repo files to an OC disk/diskette, preserving paths. Boot the computer.

Run `install` to install to a hard drive (needs a second writable HDD).

To install from the internet instead, boot a stock OpenOS diskette with an
internet card and a formatted hard drive attached:

```
wget -f https://raw.githubusercontent.com/Bufka2011/Freax/main/webinstall.lua /tmp/webinstall.lua
lua /tmp/webinstall.lua
```

`webinstall` streams the whole system onto the drive, sets its label and
boot address, then offers to reboot. See `man webinstall` (or `--help`).

After that, use packages without leaving the game: `apt update`, then
`apt install PACKAGE`, `apt upgrade` (needs an internet card). OS
self-update is separate: `apt sysupdate`, `apt sysupgrade`, then
`reboot` when asked (versioned by `/VERSION`).

## Requirements

- OpenComputers (GTNH fork, 1.7.10).
- Minimum RAM: ~384K in practice - the kernel and boot libraries dominate
  the floor (the kernel alone is ~87K of Lua).
- Recommended: a hard drive (for `install`) and an internet card (for `apt`).

## Files

- `boot/kernel/main.lua` - the kernel (~2600 lines).
- `init.lua` - boot entry point.
- `webinstall.lua` - OpenOS-side bootstrap that installs Freax over the
  network onto a hard drive.
- `bin/*.lua` - programs and coreutils.
- `bin/apt.lua`, `bin/dpkg.lua` - package management front ends.
- `bin/dpkg-deb.lua` - build and inspect `.fpkg` archives.
- `bin/apt-ftparchive.lua` - generate repository `Packages`/`Release` indexes.
- `lib/*.lua` - libraries (fs, shell, term, event, auth, thread, etc.);
  `lib/fpkg.lua`, `lib/dpkg.lua`, `lib/apt.lua` implement the package stack.
- `usr/man/*` - man pages (extensionless).
- `etc/` - config (motd, passwd, shadow, hostname, apt sources).
- `manifest` - shipped-file list driving `install`, `apt sysupgrade`, and
  demo protection.
- `selfcheck.lua` - dev smoke test (not installed).

### Packages

A package is a plain, uncompressed `.fpkg` archive: a control stanza
plus data entries for regular files, conffiles, directories, and
symlinks. `dpkg-deb -b` builds one from a `DEBIAN/control` directory;
on success it prints the archive's SHA256 and size for indexing.
`dpkg` drives unpack/configure/remove and records state under
`/var/lib/dpkg`; `apt` adds repositories, dependency resolution, and
downloads.

Host a repository with the standard tree:

```
dists/<suite>/Release
dists/<suite>/<component>/binary-all/Packages
pool/<component>/<package>_<version>_all.fpkg
```

Build the indexes from the repository root with `apt-ftparchive
packages pool` and `apt-ftparchive release dists/<suite>`, then point
`/etc/apt/sources.list` at it with a `deb URI <suite> <component>`
line. OS self-update (`apt sysupdate`/`sysupgrade`) still uses the bare
URL fallback and is independent of package sources.

See AGENTS.md for detailed development conventions.

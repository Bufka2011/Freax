# FREAX - Linux-like OS for OpenComputers

Freax is a from-scratch OpenOS replacement for the OpenComputers mod
(Minecraft 1.7.10, GTNH fork). Named after the original name Linus
Torvalds rejected for Linux.

Kernel-mediated hardware access, real process credentials, bash-inspired
shell, and FHS filesystem layout.

## Design

- **Microkernel-ish**: coroutine processes with private `_ENV`, no
  ambient hardware authority. All hardware goes through `freax.*` syscalls;
  `component` is an OpenOS-compat bridge over those (`lib/component.lua`).
- **Credentials**: kernel-owned real/effective UID/GID, root-only machine
  controls, same-user process control, protected shadow DB, and non-root
  writes restricted to the account's own home and private temporary tree.
  This is a path policy, not POSIX mode bits: there is no per-file ownership
  yet, so any account can write inside another account's home.
- **Preemption by OC runtime**: the host kills scripts that run too long
  without yielding. That error unwinds through ONE coroutine - the hog
  dies, the kernel lives.
- **Shell**: bash-ish - pipes `|`, redirects `> >> < 2>` `2>&1`,
  chaining `; && ||`, vars `$VAR`, aliases, source, foreground wait/kill
  (no background `&` job control yet).

## Status

Milestone reached: **M5** (multi-user credential boundary + shared runtime).

- Kernel: scheduler, process table, syscall sandbox, VFS with mounts
  (incl. read-only), pipes (8K buffer), virtual symlinks (RAM table, lost
  on reboot), parent PID tracking, graceful shutdown/reboot signalling,
  ANSI SGR parsing in `ttyWrite`, Ctrl+C foreground-tree kill,
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
  keybinds), ln, lua repl, ps (parent tree, UID, state, fd count), kill,
  dmesg, df, mount/umount (ro), free, uptime, date, time, yes, which,
  printenv, hostname, cd, pwd, set/unset, source, rc, reboot/shutdown,
  components/lshw/address/primary, flash, label, resolution, redstone,
  wget, pastebin, man, login, passwd, su, whoami, adduser, useradd,
  userdel.
- Package management: `apt`/`dpkg` with repositories (Debian-style
  `deb` source lines), index download and verification, dependency
  resolution, install/remove/upgrade/purge, maintainer scripts
  (`preinst`/`postinst`/`prerm`/`postrm`), and conffile handling.
  Archives use the uncompressed `.fpkg` format. The base system itself is
  the virtual package `sys` (the `/manifest` file set, versioned by
  `/VERSION`), so `apt update` and `apt upgrade` cover packages and the OS
  together; there is no separate self-update command.

## Accounts and privileges

- `login` verifies `/etc/shadow` and starts the session with the account's
  kernel credentials through `freax.spawnAs`. `USER`/`LOGNAME` are display
  only and authorize nothing.
- Root-only: mount/umount, disk label writes, EEPROM writes, boot address,
  redstone, screen resolution, reboot/shutdown, `apt`/`dpkg` mutation,
  `install`, `systemctl`, `adduser`/`useradd`/`userdel`.
- `su` and `passwd` are the only setuid programs. `su` refuses a passwordless
  root account from an unprivileged session.
- A non-root process may write inside its own home and `/tmp/<uid>`, and
  may not read `/etc/shadow`. `kill` and `wait` are limited to the same UID
  (root may target anything).
- Password hashes are salted SHA-256, not a slow KDF: treat offline disk
  access as a real risk.

Freax targets practical OpenComputers use, not complete Linux/POSIX or
OpenOS parity. Missing major work includes persistent POSIX mode metadata
(per-file ownership), background job control, modem APIs, signed
repositories, transactional OS updates, persistent symlinks, and network
policy per service. Removable-media autorun stays disabled because
kernel-phase autorun would bypass process isolation.

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
self-update is part of the same command: `apt update`, `apt upgrade`, then
`reboot` when asked. The system appears as the package `sys`; only files
whose `SHA256SUMS` checksum changed are downloaded, and every installed
file is re-hashed afterwards (`apt verify` re-checks the whole tree).

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
- `manifest` - shipped-file list driving `install`, the `sys` upgrade in
  `apt upgrade`, and demo protection.
- `selfcheck.lua` - installed in-game smoke test (`lua /selfcheck.lua`).

### Packages

A package is a plain, uncompressed `.fpkg` archive: a control stanza
plus data entries for regular files, conffiles, and directories.
Archive tools can represent symlinks, but system installation rejects them
until VFS links persist across reboot. `dpkg-deb -b` builds one from a `DEBIAN/control` directory;
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
line. The `sys` release uses the bare-URL fallback and is independent of
package sources (`apt update --source=URL` overrides it).

See AGENTS.md for detailed development conventions.

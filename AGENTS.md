# Freax Agent Notes

Freax is a Lua 5.2-ish OS for OpenComputers (Minecraft 1.7.10/GTNH). The
repository root mirrors the installed `/`; read `README.md` for current user
features rather than duplicating that status here.

## Verification

- The host has `luajit`, but no OpenComputers runtime. Host checks prove syntax
  only; never claim behavioral success from them.
- Syntax-check every changed Lua file individually:
  `luajit -e 'assert(loadfile("path/to/file.lua"))'`.
- There is no CI, test suite, linter, formatter, or typechecker.
- Behavioral smoke testing is in-game: `lua /selfcheck.lua`. The user runs it
  and reports results; it may write a failure marker under `/tmp` because
  uninstalled media can have a read-only root.
- `install` testing needs a second writable HDD. Tmpfs targets are intentionally
  skipped; `--to=ADDR` forces a target and `--from=ADDR` pins the source.

## Shipping Files

- `manifest` is the single shipped-file list used by the installer, the `sys`
  updater, and demo-mode protection. Add every new shipped file there.
- `apt/` is hosted package-repository content, not installed OS content; do not
  add its indexes or archives to `manifest`.
- `bin/install.lua` and `lib/sysupdate.lua` skip dev-only manifest entries
  (`.gitignore`, `README.md`, `mksums.lua`);
  `/etc/hostname` is machine-local. `/etc/passwd` and `/etc/shadow` are
  generated, preserved state and must not be added to `manifest`.
- `VERSION` is the only version source. Do not hardcode it in `etc/motd` or
  elsewhere.
- After changing any file listed by `manifest`, run `luajit mksums.lua` and
  include the resulting `SHA256SUMS`. A stale checksum index makes `sys`
  upgrades fall back to downloading the full release.
- `usr/man/*` pages are extensionless text, not Lua files.

## Runtime Architecture

- `init.lua` mounts the boot filesystem, loads `boot/kernel/main.lua`, and
  hands off to it. The kernel starts `/sbin/systemd.lua`, falling back to
  `/bin/login.lua`, then `/bin/sh.lua`.
- Processes are coroutines with private environments. The scheduler resumes
  every live process on each 0.05 s tick, including idle ticks, so daemon and
  sleep/poll code must yield through Freax APIs.
- Hardware authority belongs to the kernel. Process code uses `freax.*`;
  `lib/component.lua` is the OpenOS compatibility bridge and `computer` is an
  information-only subset.
- OC filesystem proxies use dot calls such as `fs.open(path)`, not method calls.
- `/dev` is mounted lazily on first access. Symlinks exist only in kernel RAM,
  disappear on reboot, and package installation rejects symlink entries.
- Shell parsing/execution is in `lib/sh.lua`; `bin/sh.lua` is the REPL and
  builtin registry. Its `runLine` call stays protected so command errors cannot
  kill the login shell.
- `os.execute` waits for the child but returns `true` regardless of its exit
  code; do not use it as a success test.

## Shared Libraries

- Only `fs`, `term`, `text`, `transforms`, `package`, and `filesystem` are in
  the kernel `SHARED` allowlist. Adding a library permanently raises the
  machine memory floor; package tooling and stateful shell modules must remain
  per-process.
- Shared modules compile into `sharedEnv`. Their `freax`, `io`, and `os` values
  are dispatch proxies resolved through the currently scheduled process. Never
  capture process-specific state at module load time.
- `lib/computer.lua` and `lib/unicode.lua` are require shims for kernel-injected
  globals. `lib/bit32.lua` is the per-process fallback when host `bit32` lacks
  the Lua 5.2 API.

## Credentials

- Authorization uses kernel-owned `uid/euid/gid/egid`; `USER` and `LOGNAME`
  are display-only.
- Non-root writes are confined to the process home and `/tmp/u<uid>`; shadow
  data is unreadable outside root or the caller's own home. This is path policy,
  not POSIX ownership, so accounts can still write inside another account's
  home if that path is used as their configured home.
- Keep the setuid surface limited to `/bin/su.lua` and `/bin/passwd.lua`.
  Sessions are created with `freax.spawnAs`; normal exec resets effective IDs.
- Mounting, machine controls, and `spawnAs` are root-only. `kill` and `wait`
  require root or matching UID.

## Memory Constraints

- Real target machines run near a 384K floor; kernel and boot libraries dominate
  retained memory. Avoid whole-file or whole-archive buffering.
- Stream I/O in 4K chunks. Never append chunks with `data = data .. chunk`;
  when a complete string is unavoidable, collect parts and call
  `table.concat` once.
- OpenComputers sandbox `load` does not support reader functions. Use
  `load(string, name, "t", env)` even when streaming would be preferable.
- Installer verification deliberately uses `fs.size` instead of rereading
  copied files. Package/update hashes must use streaming
  `sha256.new():update():hex()`.

## Package And OS Updates

- `lib/fpkg.lua` owns `.fpkg` format/version/dependency primitives;
  `lib/dpkg.lua` owns unpack/configure/remove, conffiles, scripts, and installed
  state; `lib/apt.lua` owns sources, indexes, resolution, and downloads.
- The base OS is the virtual package `sys`, implemented by
  `lib/sysupdate.lua`. There are no `apt sys*` commands: `apt update` refreshes
  it, `apt upgrade` applies it, `apt install sys` reapplies it, and
  `apt verify [--repair]` checks it.
- Package repositories use `deb` lines. The `sys` updater ignores those and
  uses the first bare URL in `/etc/apt/sources.list`, or its built-in GitHub
  default. Keep the shipped sources file to `deb` lines only.
- Network fetches add cache-busters because GitHub raw may serve stale release
  files. Preserve that behavior when changing download code.
- `lib/sysupdate.lua` preserves `/etc/passwd`, `/etc/shadow`, and
  `/etc/hostname`; changes to `init.lua` or the kernel require an in-game reboot.

## Before A Commit

- Syntax-check every touched `.lua`; regenerate `SHA256SUMS` if a manifest file
  changed; inspect `git status`.
- Never commit ignored in-game leftovers such as `s_*.txt`, `*.bak`,
  `dmesg_dump.txt`, or `iotest.txt`.
- Do not commit unless the user explicitly requests it.

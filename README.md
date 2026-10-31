# sysreport

> One command that tells you whether a Linux host is healthy, and exits non-zero when it is not, so cron or a monitoring agent can act on it.

## Quick start

```bash
git clone https://github.com/<user>/sysreport && cd sysreport
./sysreport.sh
```

Requirements: bash 4.3 or newer, the standard procps and coreutils tools, and `jq` for JSON output. `ss` and `systemctl` are optional: if one is missing, that section is skipped with a warning on stderr instead of crashing the run. Tested on Ubuntu 24.04.5 LTS with ShellCheck 0.9.0.

## Usage

```bash
./sysreport.sh                          # colored table; exit 0 if everything is under threshold
./sysreport.sh --format json | jq .     # machine-readable
./sysreport.sh --threshold 70           # warn above 70% instead of 80%
./sysreport.sh -o report.txt            # write to a file (no color codes in it)
NO_COLOR=1 ./sysreport.sh | cat         # plain text; color is also off whenever stdout is not a terminal
```

| Option | Meaning |
|---|---|
| `-f, --format table\|json` | Output format (default `table`) |
| `-o, --output FILE` | Write to FILE instead of stdout |
| `-t, --threshold N` | Warn above N percent for disk, memory and inodes (default 80) |
| `-h, --help` | Usage text |

| Exit code | Meaning |
|---|---|
| 0 | Every check is under the threshold |
| 1 | A check exceeded the threshold, or a systemd unit has failed |
| 2 | Usage error (unknown option, missing value, bad format or threshold) |

## What it reports

Host (name, kernel, distro, uptime, UTC time), CPU (cores, load average, load per core), memory (total, used, available, swap, percent used), disk and inode usage per filesystem, process count with the top 5 by CPU and by memory and any zombies, listening TCP ports with the owning process, failed systemd units, and logged-in users.

## Example output

A real run on a 2-vCPU, 4 GB Ubuntu 24.04 VM (colors omitted):

```
sysreport 1.0.0  2026-10-29T17:28:17Z

Host
  Hostname:       lab
  Kernel:         6.8.0-147-generic
  Distro:         Ubuntu 24.04.5 LTS
  Uptime:         up 7 minutes

CPU
  Cores:          2
  Load (1/5/15):  0.10 / 0.13 / 0.09
  Load per core:  0.05

Memory
  Total:          3.8 GB
  Used:           0.4 GB
  Available:      3.4 GB
  Swap used:      0.0 GB
  Used percent:   10.1%

Disk
  Mount                       Size    Used   Use%
  /                            20G    2.4G    12%
  /boot                       924M    123M    15%
  /boot/efi                   110M    6.4M     6%

Inodes
  Mount                      Use%
  /                            5%
  /boot                        2%

Processes
  Total:          111
  Zombies:        0

Listening TCP ports
  0.0.0.0:22                   -
  127.0.0.54:53                -
  127.0.0.53%lo:53             -
  [::]:22                      -

Failed systemd units
  none

Result
  All checks under threshold (80%)
```

(The per-process tables are trimmed here; see `examples/report.txt` for the full output.) The `-` in the ports section means the owning process is not visible to a non-root user; run with `sudo` to see names such as `sshd` and `systemd-resolve`.

JSON output, abbreviated:

```json
{
  "version": "1.0.0",
  "threshold": 80,
  "exit_code": 0,
  "warnings": [],
  "host": { "name": "lab", "kernel": "6.8.0-147-generic", "distro": "Ubuntu 24.04.5 LTS" },
  "cpu": { "cores": 2, "load1": 0.14, "load_per_core": 0.07 },
  "memory": { "total_gb": 3.8, "used_pct": 10.0 },
  "disks": [ { "mount": "/", "size": "20G", "used": "2.4G", "used_pct": 12 } ]
}
```

## What this demonstrates

- Exit codes designed for monitoring: 0 for healthy, 1 for a problem found, 2 for a usage error, so a caller can tell "the host has a problem" from "I ran it wrong".
- Graceful degradation: a missing `ss` or `systemctl` skips one section with a warning and the rest still runs.
- Valid JSON by construction: values go through `jq --arg` and `--argjson`, never string concatenation, so a quote in a value cannot break the output.
- Safe Bash: `set -Eeuo pipefail`, quoted expansions, an `ERR` trap that turns any unexpected failure into exit 2 with the failing line number, and a startup check that refuses to run if a required tool is missing.
- Clean under ShellCheck with no suppressions.

## Key decisions

| Decision | Chose | Rejected | Why |
|---|---|---|---|
| Usage-error exit code | 2, through a `need_value` check | `${2:?msg}` from the lab's pattern | `${2:?}` exits 1, which here means "a threshold was exceeded". A monitor could not tell a typo from a full disk |
| Memory source | `/proc/meminfo` (`MemAvailable`) | `free` | Stable fields, no locale-dependent output, and "available" is the number that matters |
| Distro name | Read `PRETTY_NAME` with `awk` | `. /etc/os-release` | Sourcing the file runs it as code and collided with this script's own `VERSION` constant (see below) |
| JSON | `jq -n --arg/--argjson` | `printf` templates | Correct escaping for free |
| Trimming output under `pipefail` | `awk 'NR <= N'` | `head -N` | `head` can close the pipe early and make the whole pipeline fail unpredictably |
| Failed systemd units | Set exit code 1 | Report only | A failed unit is exactly what a monitoring caller wants to be told about |
| Zombie processes | Report only | Set exit code 1 | A single short-lived zombie is not an alert on its own |
| Missing required tool (`df`, `ps`, ...) | Fail at startup, exit 2, naming the tool | Let the section come out empty | See "What broke" 4: an empty section with exit 0 looks like a healthy host |
| Missing optional tool (`ss`, `systemctl`) | Skip that section with a warning | Fail | The rest of the report is still useful |

## What broke and how I fixed it

### 1. Every test crashed with `VERSION: readonly variable`, exit code 1
**What I saw:** `/etc/os-release: line 4: VERSION: readonly variable`, and the script exited with code 1.
**What was actually wrong:** To get the distro name I ran `. /etc/os-release`, which executes the file. The file assigns `VERSION="24.04.5 LTS (Noble Numbat)"`, and my script declares `readonly VERSION="1.0.0"`. The assignment failed, and `set -e` killed the script. Worse, the exit code was 1, the same code that means "threshold exceeded", so a monitor would have reported a disk problem.
**How I found it:** The error named both the file and the variable. Searching the script for `VERSION` showed the `readonly` declaration.
**Prevention:** Read the one key needed with `awk` instead of executing the file. See limitation 5 about unexpected crashes still exiting 1.

### 2. A pseudo-filesystem showed up as a disk
**What I saw:** An extra row, `/sys/firmware/efi/efivars`, with 6% used, in the disk report.
**What was actually wrong:** That mount is `efivarfs`, a view of UEFI firmware variables, not storage. Its percentage means nothing, and a full one would have raised a false disk alert.
**How I found it:** I tested `collect_disk` on its own and compared the rows with what I expected to see (`/`, `/boot`, `/boot/efi`).
**Prevention:** Exclude `tmpfs`, `devtmpfs`, `squashfs` (snap packages are always 100% full), `overlay` and `efivarfs`. The inode pass skips filesystems that report `-` for inode use.

### 3. The tool listed itself as the top CPU consumer, at 200%
**What I saw:** `ps` ranked first in "top 5 by CPU" at 200%.
**What was actually wrong:** `ps` reports `%cpu` as CPU time divided by the process's lifetime so far, not current usage. A process that has run for a few milliseconds can show an absurd figure, and the `ps` call the script makes is always brand new.
**How I found it:** The isolated test of `collect_procs` printed it.
**Prevention:** Filter the script's own `ps` out of both lists. The figures are still lifetime averages, which is documented below.

### 4. A missing tool produced an empty section and exit code 0
**What I saw:** I deliberately ran the script with `df` removed from `PATH`. It printed `df: command not found` twice, then carried on, produced a report with an empty Disk section, and exited 0.
**What was actually wrong:** `df` ran inside a process substitution (`done < <(df ... | tail ...)`). Bash does not propagate a failure out of a process substitution, so my `ERR` trap only ended that little subshell and the main script saw empty input. For a monitoring tool this is the worst outcome: a broken check that looks like a healthy host.
**How I found it:** The "break it deliberately" step of the lab. My first attempt at simulating a missing tool was itself wrong: `command -v df` printed my shell's alias instead of a path, so the fake `PATH` held a dangling link. Switching to `type -P` fixed the test, and the real bug then showed.
**Prevention:** Check every required command at startup with a `need` helper and exit 2 naming the missing one. Optional tools (`ss`, `systemctl`) still degrade to a warning. Each missing-tool case is covered by a test.

## Known limitations

1. Mount points with spaces in their names are not parsed correctly (`df -P` separates columns with spaces).
2. Listening ports show the owning process only when run as root.
3. `%cpu` in the top lists is a lifetime average from `ps`, not a live sample, and the list can include the script's own shell or pipeline.
4. If `systemctl` is missing, the systemd section prints `none` and the warning appears only on stderr.
5. When a failure happens inside a command substitution, the `ERR` trap fires in the subshell and again in the parent, so the `ERROR: unexpected failure` line can appear twice. The exit code is still 2.

## Repo layout

| File | What it is |
|---|---|
| `sysreport.sh` | The script |
| `examples/report.txt` | Full table output from a real run |
| `examples/report.json` | Full JSON output from the same host |
| `README.md` | This file |

# AutoMapNetworkDrives

Maps SMB shares from every reachable host on your local Windows workgroup LAN
as persistent drive letters. Run `Map-NetworkDrives.cmd`; answer one prompt
per host that needs creds. Re-run only when new hosts/shares appear.

## What it does

1. Auto-detects your local subnet from the active network adapter.
2. Probes TCP 445 on every host in the subnet in parallel (default 64 concurrent, 2-second timeout).
3. Resolves each responsive host's name through a DNS reverse → LLMNR → mDNS → NetBIOS chain.
4. Enumerates each host's user shares (skips `IPC$`, `ADMIN$`, `C$`, `print$`, and any other share whose name ends in `$`).
5. Prompts once per host for credentials when required; stores them in Windows Credential Manager and reuses them on subsequent runs.
6. Assigns a drive letter — honors a previously-learned letter from the config, else picks the next free letter starting at `Z:` and counting down.
7. Creates the mapping with `/persistent:yes` so Windows reconnects it at every logon.
8. Sets a friendly Explorer label of the form `<share> on <short-hostname>` (e.g. `home on MyNAS`).

## Requirements

- Windows 11. Runs under Windows PowerShell 5.1 (the in-box shell) and PowerShell 7+.
- Workgroup networking. Domain / Active Directory environments are out of scope.
- Outbound network access to TCP port 445 on hosts you want to discover.
- No external dependencies beyond what ships with Windows. No PowerShell modules from the Gallery.

## First run

1. Open a normal (non-elevated) PowerShell or `cmd` window. Do **not** run as Administrator — mappings created in the elevated logon session are invisible to your normal Explorer (Windows UAC "linked connections" behavior). The script warns you on startup if it detects an elevated context.
2. Run `.\Map-NetworkDrives.cmd`. You can also double-click it from Explorer; the window pauses at the end so you can read the output.
3. When you see `N host(s) require credentials`, a Windows credential dialog appears for each (sometimes hidden behind the cmd window — check the taskbar). Cancel any prompt for a host you don't have credentials for; the host is logged and skipped.
4. After the script finishes, the drives appear in Explorer with their friendly labels.

## Re-running

Re-run the launcher whenever:

- A new host comes online and you want to pick up its shares.
- A share is added to a host you've already mapped.
- Stored credentials for a host stop working (the script reprompts on the next run).

The script is idempotent: shares already mapped to the correct letter are left alone, no disconnect/reconnect churn.

## Optional flags

| Flag | Purpose |
|---|---|
| `-DryRun` | Discover and enumerate, but do not map drives, write config, or set labels. |
| `-Detailed` | Mirror the full log stream to the console (timestamped lines, every entry — same content as the log file). Without this flag, the console shows only the end-user-relevant lines: host headers, drive map results, warnings, errors, and a closing summary. |
| `-Silent` | Suppress all console output and skip credential prompts. Hosts without stored creds are logged and skipped. Intended for batch / scripted re-runs. Takes precedence over `-Detailed` if both are passed. |
| `-NoUpdate` | Skip the launcher's auto-update step (the fast-forward `git pull` it normally runs before invoking the PowerShell script). Useful when developing locally. |
| `-TimeoutMs N` | Override the per-batch TCP 445 probe timeout (milliseconds). |
| `-Parallelism N` | Override the number of concurrent TCP probes per batch. |

## Auto-update

When you launch via `Map-NetworkDrives.cmd` and the folder is a git clone of this repository, the launcher automatically fetches and fast-forwards to `origin` before invoking the PowerShell script. Updates to `Map-NetworkDrives.ps1` take effect on the same run; updates to `Map-NetworkDrives.cmd` itself land on the next run. If `git` is missing but `winget` is available, the launcher installs `Git.Git` first (one-time, may UAC prompt). Auto-update skips silently if you're offline, or with a short message if your local branch has diverged from origin. Pass `-NoUpdate` to bypass for a single invocation.

## Where things live

| Path | Purpose |
|---|---|
| `Map-NetworkDrives.cmd` | The launcher — the file you run. |
| `src/Map-NetworkDrives.ps1` | The implementation. |
| `docs/REQUIREMENTS.md` | Full functional and non-functional requirements. |
| `%APPDATA%\AutoMapNetworkDrives\config.json` | Auto-learned drive-letter assignments and scan settings. Edit by hand to pin a specific letter for a UNC. |
| `%LOCALAPPDATA%\AutoMapNetworkDrives\logs\map.log` | Run log. Rotates at 5 MB; 3 backups kept. Credentials are never logged. |
| Credential Manager — Generic, target `AutoMapNetworkDrives:<host>` | Stored credentials for the script's own re-use across runs. List with `cmdkey /list:AutoMapNetworkDrives*`. |
| Credential Manager — Domain Password, target `<host>` | Same credentials, in the format Windows uses to reconnect persistent SMB mappings at logon. Without these, drives come back as disconnected ghosts after a reboot. The script writes both entries when it handles a host's credentials. |

## Dev notes

Useful commands while developing or testing — these only affect the **current logon session's elevation tier** (run from a non-elevated cmd to clear the drives that show up in your normal Explorer; rebooting clears everything regardless).

**Delete every mapped network drive**

```
net use * /delete /y
```

`*` matches all current SMB connections (drive letters and `IPC$` sessions); `/y` skips the confirmation prompt.

**Delete a single mapped network drive**

```
net use Z: /delete /y
```

Replace `Z:` with the letter you want to remove. PowerShell equivalent: `Remove-SmbMapping -LocalPath 'Z:' -Force -UpdateProfile`.

## Full requirements

For the complete functional and non-functional specification, see [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md).

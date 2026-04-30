# AutoMapNetworkDrives — Requirements

## 1. Overview

A PowerShell script that, when run manually on a Windows 11 workgroup machine, discovers SMB hosts on the local subnet and creates **persistent** network drive mappings for their shares. Mappings persist across reboots; the script is re-run only when new hosts/shares appear, when credentials change, or when something needs reconciliation.

## 2. Goals

- Discover live SMB hosts on the local subnet without user-maintained host lists.
- Map user shares from those hosts as **persistent** Windows network drives — created once, restored by Windows at every subsequent logon.
- Provide stable, predictable drive letters across runs for known shares.
- Handle authentication once per host, then reuse stored credentials silently.
- Keep the user's existing manual mappings and persistent mappings intact.

## 3. Non-Goals

- Domain / Active Directory environments (workgroup only).
- Mapping shares from the local computer (already accessible locally).
- Mapping admin shares (`C$`, `ADMIN$`, etc.) or system shares (`IPC$`, `print$`).
- Cross-subnet / VLAN discovery.
- A graphical user interface.
- Automatic configuration sync across machines.

## 4. Functional Requirements

### 4.1 Execution Model

- **FR-1.** *(Removed 2026-04-29 — stakeholder decision: no automatic at-login execution. Mappings are persistent (FR-16) and rebuilt by Windows itself at logon.)*
- **FR-2.** Invoked manually from a PowerShell or `cmd` console; produces human-readable progress output to the console (also written to the log file per FR-31).
- **FR-3.** A single instance enforcement — concurrent manual runs must not corrupt state.

### 4.2 Discovery

- **FR-4.** Auto-detect the local subnet from the active network adapter's IPv4 address and prefix length.
- **FR-5.** Scan the detected subnet by attempting a TCP connection to port 445 on each host IP, in parallel.
  - **FR-5.1.** Default per-host probe timeout: **2000 ms** (configurable). Originally 500 ms; raised after a recently-rebooted laptop missed the 500 ms window even though TCP/445 was reachable in milliseconds once the machine was fully up.
  - **FR-5.2.** Default parallelism: **64** concurrent probes (configurable).
- **FR-6.** Exclude the local computer's own IP addresses from the scan and from any subsequent share enumeration.
- **FR-7.** For each responsive host, attempt to resolve a hostname using the following chain, in order, stopping at the first success:
  - **FR-7.1.** Unicast DNS reverse lookup (PTR record).
  - **FR-7.2.** LLMNR (Link-Local Multicast Name Resolution).
  - **FR-7.3.** mDNS (`.local` resolution — covers NAS appliances, macOS, and Linux hosts running Avahi).
  - **FR-7.4.** NetBIOS Node Status query (legacy NetBIOS-over-TCP/IP hosts).

  Implementation note: on Windows, `Resolve-DnsName` covers FR-7.1 through FR-7.3 in a single call; FR-7.4 is provided by `nbtstat -A` as a fallback.

  - **FR-7.5.** If a hostname is resolved, mappings use the UNC path `\\HOSTNAME\Share`. The full resolved name is used as-is (e.g. `\\MyNAS.local\Share`); no suffix stripping.

    **Exception (short-name fallback)**: if SMB enumeration against the FQDN fails with one of the "bad net path" Win32 codes — `ERROR_BAD_NETPATH` (53), `ERROR_BAD_NET_NAME` (67), or `ERROR_NO_NET_OR_BAD_PATH` (1203) — the script retries enumeration against the short hostname (everything before the first dot). If the short name produces a successful enumeration — or any error not in the bad-net-path set (e.g. an authentication error, which is still actionable) — the script uses the short name as the working hostname for all downstream operations on that host (auth session, UNC path, mapping, label key, Credential Manager target name). This handles router-DNS suffixes such as `.example.lan`, which the gateway resolves but the target host's SMB stack does not honor.
  - **FR-7.6.** If all resolution methods fail, fall back to `\\IP\Share` and write a warning to the log indicating that a stable name (static DNS / hosts file entry, or enabling mDNS/Avahi on the host) is recommended.
- **FR-8.** For each responsive host, enumerate available SMB shares.
  - **FR-8.1.** Enumeration must work against an authenticated session — i.e. after stored credentials from FR-12 have been applied to the host (typically by establishing an `IPC$` connection first), share enumeration must succeed.
  - **FR-8.2.** Enumeration must work against modern Windows hosts (Windows 10/11 with default settings) and modern NAS appliances. The script uses the **Win32 `WNetEnumResource` API via P/Invoke** as the primary enumeration mechanism (this is the same API Windows File Explorer uses to browse `\\HOST`). It works against any SMB host the user can authenticate to via the `IPC$` session established per FR-12.1, returns structured data (no locale-dependent text parsing), and automatically excludes IPC and admin shares.

    Spike results (2026-04-29) against `\\MyNAS.local` (FreeNAS, post-IPC$ auth):
    - `WNetEnumResource` P/Invoke: ✅ returned `home` (auto-filtered IPC$).
    - `net view \\HOST /all`: ✅ returned `home` and `IPC$` with type info; localized output, requires text parsing.
    - `Get-CimInstance Win32_Share -ComputerName HOST`: ❌ failed with WinRM TrustedHosts error — incompatible with workgroup environments without configuration the user should not have to do.

    `net view` is retained as a documented **fallback** for the rare case where `WNetEnumResource` fails against a specific host; the script attempts it only when the primary mechanism returns an error other than "host unreachable".
  - **FR-8.3.** If share enumeration fails for an authenticated host, log an error identifying the host and the underlying error code; do not abort the run — continue with other hosts.

### 4.3 Share Filtering

- **FR-9.** Map only user shares. Skip:
  - The IPC share (`IPC$`)
  - The print share (`print$`)
  - Admin shares (`ADMIN$`, single-letter-plus-`$` shares such as `C$`–`Z$`)
  - Any other share whose name ends in `$` (treated as hidden/admin by default)
- **FR-10.** No allowlist/denylist required for v1; share filtering is rule-based as above.

### 4.4 Credentials

- **FR-11.** Credential prompting follows a **two-phase model** in manual mode:
  - **FR-11.1.** Phase 1 (discovery): scan all hosts, resolve hostnames, and attempt share enumeration using credentials already stored in Windows Credential Manager (FR-12). Hosts without stored credentials are recorded but not prompted-for yet.
  - **FR-11.2.** Phase 2 (batched prompt): after the full scan completes, present the user with the consolidated list of hosts that require credentials and prompt for each in turn. Each successful prompt result is written to Credential Manager keyed by the resolved hostname.

    **Retry on likely typos**: if a prompted credential is rejected with `ERROR_LOGON_FAILURE` (Win32 1326) or `ERROR_INVALID_PASSWORD` (Win32 86) — both signals of a probable typo — the script reports the failure and asks the user whether to retry, capped at **3 attempts per host**. Other authentication errors (`ERROR_ACCOUNT_LOCKED_OUT`, `ERROR_PASSWORD_MUST_CHANGE`, `ERROR_ACCOUNT_DISABLED`, etc.) skip the host immediately because re-prompting cannot resolve them and could risk further lockout. The user may explicitly decline a retry by answering `n` to the prompt, in which case the host is skipped.
  - **FR-11.3.** Phase 3 (mapping): re-attempt enumeration for any host whose credentials were just provided, then proceed with mapping for all hosts that have usable credentials.
  - **FR-11.4.** When invoked with `-Silent`, phase 2 is skipped entirely. Hosts without stored credentials are logged and skipped without prompting. Intended for batch / scripted re-runs where no credential UI is wanted.
  - **FR-11.5.** Credentials in Credential Manager are stored as **two** entries per host, both keyed off the same `<resolved-hostname>` (the value used in the UNC path per FR-7.5 — full FQDN, including `.local` or short-name fallback if present):
    - **Generic** credential under target name `AutoMapNetworkDrives:<resolved-hostname>` — used by the script itself to reuse credentials silently on subsequent runs (FR-12).
    - **Domain Password** credential under target name `<resolved-hostname>` — used by **Windows** to reconnect persistent SMB mappings at user logon. Persistent mappings to credential-required hosts come back as disconnected ghosts after sign-out / reboot if this entry is missing (Win32 85 "The local device name is already in use" when the user clicks the drive in Explorer); Windows' login-reconnect logic looks for credentials under the bare server name, not the script's prefixed Generic key.

    Both entries are written by the script after a successful credential establishment (Phase 2 fresh prompt, or Phase 1 reuse where stored credentials authenticate cleanly). Both are encrypted at rest by DPAPI; neither is written to disk in plaintext by the script.
- **FR-12.** When credentials are already stored in Credential Manager for a host, retrieve and use them silently.
  - **FR-12.1.** Before invoking the chosen share-enumeration mechanism (FR-8) against a host that requires authentication, the script must establish an authenticated SMB session by mounting `\\HOST\IPC$` with the available credentials (e.g. `net use \\HOST\IPC$ /user:NAME password`). Enumeration is attempted only after the session is established. If session establishment fails (bad credentials → System error 1326, or similar), the host is treated as auth-required-but-unknown for this run, and re-prompted in phase 2 (manual mode) or skipped (login mode).
- **FR-13.** Credentials are never written to the config file or log files.

### 4.5 Drive Letter Assignment

- **FR-14.** Hybrid strategy:
  - **FR-14.1.** If the config file specifies a preferred drive letter for a UNC path (`\\HOST\Share`), use that letter.
  - **FR-14.2.** Otherwise, auto-assign the next available drive letter, scanning from `Z:` downward toward `D:` (skipping `A:`–`C:`).
  - **FR-14.3.** When a new auto-assigned mapping is created, append the `\\HOST\Share → letter` pair to the config file so the same letter is used on subsequent runs ("auto-learn").
- **FR-15.** Auto-assignment must skip any drive letter that:
  - Is currently in use by a local drive (e.g. removable media, optical, virtual disk).
  - Is currently in use by an existing network mapping.
  - Is reserved by the config file for a different `\\HOST\Share` (even if that share is currently unreachable).

### 4.6 Drive Display Label

- **FR-34.** When a network drive is mapped, the script sets a friendly display label of the form:
  ```
  <sharename> on <short-hostname>
  ```
  where `<sharename>` is the share name as enumerated (e.g. `home`) and `<short-hostname>` is the resolved hostname with everything after the first dot removed (e.g. `MyPC.example.lan` → `MyPC`; `MyNAS.local` → `MyNAS`).
- **FR-35.** Hostname casing in the label is preserved verbatim from the resolver — no transformation (no acronym expansion, no case normalization). If the resolver returned `MyPC`, the label uses `MyPC`.
- **FR-36.** The label is implemented by writing a `_LabelFromReg` REG_SZ value under the per-user MountPoints2 registry key for the mapping:
  ```
  HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##<host>#<share>\_LabelFromReg
  ```
  where `<host>` and `<share>` reflect the actual UNC components used for the mapping (with `#` separators in the registry key name).
- **FR-37.** The custom label is set immediately after a mapping is created (or on each run, for idempotency); it is removed when the mapping is removed.
- **FR-38.** Custom labels affect display only and have no effect on UNC resolution — UNC paths continue to use the full resolved hostname per FR-7.5.

### 4.7 Mapping Persistence

- **FR-16.** **All mappings** — both auto-discovered and config-specified — are created as **persistent** (`net use … /persistent:yes`). Windows reconnects them at logon independently of the script. The script is re-run manually only when new hosts/shares appear, credentials change, or reconciliation is needed.
- **FR-17.** *(Removed 2026-04-29 — stakeholder decision: session-only mappings eliminated. See FR-16.)*

### 4.8 Conflict Handling

- **FR-18.** Same share on the same letter → no-op; do not disturb the existing mapping.
- **FR-19.** Wanted drive letter currently holds a *different* network share → choose a different letter via the auto-assignment rules in FR-15; do not disconnect the existing mapping.
- **FR-20.** Wanted drive letter is a *local drive* → choose a different letter via the auto-assignment rules in FR-15.
- **FR-21.** Same share is already mapped under a different letter → leave the existing mapping in place; do not create a duplicate.
- **FR-22.** A persistent mapping points to an unreachable host → leave it alone (respect the user's config and Windows' own behavior).
- **FR-23.** *(Removed 2026-04-29 — stakeholder decision: no session-only mappings exist. Persistent mappings to currently-unreachable hosts are left alone per FR-22.)*

### 4.9 Configuration

- **FR-24.** Config file path: `%APPDATA%\AutoMapNetworkDrives\config.json`.
- **FR-25.** Config file format: JSON.
- **FR-26.** If the file does not exist on first run, the script creates it with default values.
- **FR-27.** The config schema includes (at minimum):
  - Drive letter preferences: array of `{ unc: "\\HOST\Share", letter: "Z" }` entries (auto-learned and user-editable).
  - Scan timeout (ms), default 2000.
  - Scan parallelism, default 64.

  Backward compatibility: existing config files containing a `persistent` field on mapping entries are still readable; the field is ignored. All mappings are persistent per FR-16.
- **FR-28.** Drive letter preferences from the config are honored across runs; entries written by auto-learn are functionally identical to entries written by the user.

### 4.10 Output & Logging

- **FR-29.** Default console output is end-user oriented: a one-line start banner, a header line per host found, one line per share mapped/skipped/failed, warnings and errors, and a closing summary of the form `Done. N mapped, M unchanged, K skipped, L failed.` (with a `(dry-run: no changes were made)` suffix when `-DryRun` is set). Diagnostic detail (subnet/scan parameters, share-enumeration internals, idempotent no-op explanations, label-set confirmations, FR cross-references) is suppressed from the console but always recorded to the log file.
  - **FR-29.1.** When invoked with `-Detailed`, the console mirrors the log file verbatim — every entry, with the full `<timestamp> <LEVEL> <message>` prefix. Intended for debugging.
- **FR-30.** When invoked with `-Silent`, the script suppresses ALL console output (only writes to the log file). Intended for batch / scripted re-runs. `-Silent` takes precedence over `-Detailed` if both are passed.
- **FR-31.** All runs write to a log file at `%LOCALAPPDATA%\AutoMapNetworkDrives\logs\map.log`. The log file contents are independent of `-Silent` / `-Detailed` (always full detail).
- **FR-32.** Log rotation:
  - Single rolling file (`map.log`).
  - Rotate at **5 MB**; rename existing `map.log` to `map.log.1`, shift `.1` → `.2`, etc.
  - Keep **3** backups (`map.log.1`, `map.log.2`, `map.log.3`); older files are deleted.
- **FR-33.** Log entries include timestamp, severity (INFO / WARN / ERROR), and message. No credentials are ever logged.

### 4.11 Auto-Update

- **FR-39.** When invoked through the launcher (`Map-NetworkDrives.cmd`), if the launcher folder is a git working tree (i.e. has a `.git` subdirectory) and the network is reachable, the launcher attempts a fast-forward `git pull` from origin before starting the PowerShell script. Updates to `src/Map-NetworkDrives.ps1` take effect on the same run because the pull happens in the launcher (cmd) before PowerShell parses the script. Updates to `Map-NetworkDrives.cmd` itself take effect on the next run.
  - **FR-39.1.** If `git` is not installed but `winget` is available, the launcher first installs the Git for Windows package via `winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements`. May trigger a UAC prompt depending on system policy.
  - **FR-39.2.** If git is unavailable (and winget cannot install it), origin is unreachable (offline run), or the local branch has diverged from origin (so a fast-forward pull is impossible), the auto-update step is skipped — silently for the offline case, with a brief `[auto-update]` console message for the divergence and missing-tooling cases. The script always continues with the locally available code.
  - **FR-39.3.** Pass `-NoUpdate` on the command line to skip the auto-update for a single invocation (e.g. when developing locally on a topic branch).

## 5. Non-Functional Requirements

- **NFR-1.** **Platform**: Windows 11. **Windows PowerShell 5.1 is the baseline target** — the script must run on a stock Windows 11 install with no additional PowerShell installation. The script must also run unchanged on **PowerShell 7+** (`pwsh`). This rules out PS 7-only constructs (e.g. `ForEach-Object -Parallel`, ternary operator, null-coalescing) in favor of constructs supported by both versions (e.g. async tasks, runspace pools).
- **NFR-2.** **Runtime**: zero external dependencies beyond what ships with Windows + PowerShell. No additional modules from the Gallery.
- **NFR-3.** **Performance**: a full scan of a /24 subnet must complete in under 5 seconds with default settings on a typical LAN.
- **NFR-4.** **Resilience**: a single unreachable / misbehaving host must not block the scan or the script's overall completion.
- **NFR-5.** **Idempotency**: running the script repeatedly with no LAN changes must converge to the same state without churn (no unnecessary disconnect/reconnect cycles).
- **NFR-6.** **Security**:
  - Credentials stored only in Windows Credential Manager.
  - No credentials written to disk in plain text.
  - No credentials written to logs.

## 6. Open / Deferred Items

The following are intentionally out of scope for v1 and may be revisited:

- Allowlist / denylist of hosts or share names.
- Per-host credential overrides via config file.
- Pruning of stale entries from Credential Manager when a host has been gone for a long time.
- Notifications (toast / tray) on mapping changes or failures.
- Mid-session re-scan (currently: only login + manual triggers).
- Multi-subnet / explicit CIDR support.
- Combining `net view` results with the TCP 445 probe.

## 7. Glossary

- **UNC path**: Universal Naming Convention path of the form `\\HOST\Share`.
- **SMB**: Server Message Block — the Windows file-sharing protocol, default on TCP port 445.
- **Workgroup**: Windows networking model with no central directory; each host authenticates clients independently.
- **Persistent mapping**: a drive mapping that Windows recreates at user logon, independent of any script. *(All mappings created by this script are persistent per FR-16.)*
- **Credential Manager**: built-in Windows credential vault (`cmdkey.exe`, `Get-StoredCredential`).

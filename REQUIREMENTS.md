# AutoMapNetworkDrives — Requirements

## 1. Overview

A PowerShell script that runs on a Windows 11 workgroup machine and automatically maps network drives for SMB shares discovered on the local subnet. Runs silently at user login and is also manually re-runnable from a console.

## 2. Goals

- Discover live SMB hosts on the local subnet without user-maintained host lists.
- Map user shares from those hosts as Windows network drives.
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

- **FR-1.** Runs silently at user login (registered as a Task Scheduler job or startup-folder entry).
- **FR-2.** Can be invoked manually from a PowerShell console; manual invocations produce human-readable progress output to the console.
- **FR-3.** A single instance enforcement — concurrent runs (e.g. login + manual) must not corrupt state.

### 4.2 Discovery

- **FR-4.** Auto-detect the local subnet from the active network adapter's IPv4 address and prefix length.
- **FR-5.** Scan the detected subnet by attempting a TCP connection to port 445 on each host IP, in parallel.
  - **FR-5.1.** Default per-host probe timeout: **500 ms** (configurable).
  - **FR-5.2.** Default parallelism: **64** concurrent probes (configurable).
- **FR-6.** Exclude the local computer's own IP addresses from the scan and from any subsequent share enumeration.
- **FR-7.** For each responsive host, attempt to resolve a hostname using the following chain, in order, stopping at the first success:
  - **FR-7.1.** Unicast DNS reverse lookup (PTR record).
  - **FR-7.2.** LLMNR (Link-Local Multicast Name Resolution).
  - **FR-7.3.** mDNS (`.local` resolution — covers NAS appliances, macOS, and Linux hosts running Avahi).
  - **FR-7.4.** NetBIOS Node Status query (legacy NetBIOS-over-TCP/IP hosts).

  Implementation note: on Windows, `Resolve-DnsName` covers FR-7.1 through FR-7.3 in a single call; FR-7.4 is provided by `nbtstat -A` as a fallback.

  - **FR-7.5.** If a hostname is resolved, mappings use the UNC path `\\HOSTNAME\Share`. The full resolved name is used as-is (e.g. `\\MyNAS.local\Share`); no suffix stripping.

    **Exception (short-name fallback)**: if SMB enumeration against the FQDN fails with `ERROR_BAD_NETPATH` (Win32 53) or `ERROR_BAD_NET_NAME` (Win32 67), the script retries enumeration against the short hostname (everything before the first dot). If the short name produces a successful enumeration — or any error other than 53/67 (e.g. an authentication error, which is still actionable) — the script uses the short name as the working hostname for all downstream operations on that host (auth session, UNC path, mapping, label key, Credential Manager target name). This handles router-DNS suffixes such as `.example.lan`, which the gateway resolves but the target host's SMB stack does not honor.
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
  - **FR-11.3.** Phase 3 (mapping): re-attempt enumeration for any host whose credentials were just provided, then proceed with mapping for all hosts that have usable credentials.
  - **FR-11.4.** During a **login** (silent) run, phase 2 is skipped entirely. Hosts without stored credentials are logged and skipped without prompting.
  - **FR-11.5.** Credentials in Credential Manager are stored under the target name `AutoMapNetworkDrives:<resolved-hostname>`, where `<resolved-hostname>` is the same value used in the UNC path per FR-7.5 (full FQDN, including `.local` if present).
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

- **FR-16.** Mappings created from explicit config entries are created with the `-Persistent` flag (Windows reconnects them at logon independently of the script).
- **FR-17.** Mappings created from auto-discovered shares are created **session-only** (no `-Persistent`); they are recreated each run.

### 4.8 Conflict Handling

- **FR-18.** Same share on the same letter → no-op; do not disturb the existing mapping.
- **FR-19.** Wanted drive letter currently holds a *different* network share → choose a different letter via the auto-assignment rules in FR-15; do not disconnect the existing mapping.
- **FR-20.** Wanted drive letter is a *local drive* → choose a different letter via the auto-assignment rules in FR-15.
- **FR-21.** Same share is already mapped under a different letter → leave the existing mapping in place; do not create a duplicate.
- **FR-22.** A persistent mapping points to an unreachable host → leave it alone (respect the user's config and Windows' own behavior).
- **FR-23.** An auto-discovered (session-only) mapping from a previous run points to a host that is no longer reachable → unmap it.

### 4.9 Configuration

- **FR-24.** Config file path: `%APPDATA%\AutoMapNetworkDrives\config.json`.
- **FR-25.** Config file format: JSON.
- **FR-26.** If the file does not exist on first run, the script creates it with default values.
- **FR-27.** The config schema includes (at minimum):
  - Drive letter preferences: array of `{ unc: "\\HOST\Share", letter: "Z" }` entries (auto-learned and user-editable).
  - Scan timeout (ms), default 500.
  - Scan parallelism, default 64.
- **FR-28.** Drive letter preferences from the config are honored across runs; entries written by auto-learn are functionally identical to entries written by the user.

### 4.10 Output & Logging

- **FR-29.** Manual runs print progress lines to the console (subnet being scanned, hosts found, shares being mapped, conflicts skipped, errors).
- **FR-30.** Login runs are silent (no console window shown to the user).
- **FR-31.** All runs (manual and login) write to a log file at `%LOCALAPPDATA%\AutoMapNetworkDrives\logs\map.log`.
- **FR-32.** Log rotation:
  - Single rolling file (`map.log`).
  - Rotate at **5 MB**; rename existing `map.log` to `map.log.1`, shift `.1` → `.2`, etc.
  - Keep **3** backups (`map.log.1`, `map.log.2`, `map.log.3`); older files are deleted.
- **FR-33.** Log entries include timestamp, severity (INFO / WARN / ERROR), and message. No credentials are ever logged.

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
- **Persistent mapping**: a drive mapping that Windows recreates at user logon, independent of any script.
- **Session-only mapping**: a drive mapping that exists only until the user logs off.
- **Credential Manager**: built-in Windows credential vault (`cmdkey.exe`, `Get-StoredCredential`).

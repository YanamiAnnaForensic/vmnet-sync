# VMnet Sync

An event-triggered VMware Workstation helper for Windows. Version 0.3.0 discovers configured VMnets, checks the corresponding host adapters after an edit, renews stale DHCP leases, verifies the results and exits.

[中文说明](README.md)

**0.3.0 passed local real-network acceptance on Windows 11 build 26200 and Workstation 17.6.3.** Original-UI changes, real DHCP repair and worker exit were verified for VMnet1, VMnet8 and custom VMnet3. Other versions still need compatibility testing. See [validation](docs/validation.md).

## Use

1. Download from [GitHub Releases](https://github.com/YanamiAnnaForensic/vmnet-sync/releases) and extract `vmnet-sync-0.3.0-windows-x64.zip`.
2. Double-click **Install.cmd** and accept UAC. The same entry upgrades 0.1/0.2, migrating legacy directories, diagnostics and the event task with rollback.
3. Edit your network in VMware's original Virtual Network Editor and click Apply.

**Status.cmd** shows task and per-network results. **Uninstall.cmd** removes the helper. Setup only snapshots desired configuration; it does not start a worker or inspect/repair live adapters.

## Scope

- Windows 10/11 x64 and built-in Windows PowerShell 5.1; no additional runtime.
- Host-only and NAT networks, including custom VMnet0–19, with a connected host adapter and VMware DHCP enabled.
- Network IDs, host/gateway addresses and subnet prefixes are discovered rather than assumed. Windows adapter aliases may be renamed.
- Host-only networks do not depend on the NAT service. Bridges, unused slots, disconnected host-adapter connections and DHCP-off networks are skipped.
- Static Windows adapter settings, disabled/missing adapters, identity mismatches and unexpected default routes are not overwritten.
- Each edited network is processed independently. An unrelated unchanged network is not inspected or repaired, even if its live address is stale.

Real Apply → audit event → SYSTEM task → cross-subnet repair → exit passed locally for VMnet1/8 and custom host-only VMnet3. Non-/24 masks and host/DHCP opt-outs were included. Custom NAT placement is covered by automated configuration/worker tests; its live acceptance remains a compatibility test.

## Execution

There is no resident product process/service, timer, boot/logon check, catch-up run or installation-time repair. Windows File System/Registry auditing and Task Scheduler launch the worker on configuration writes, including registry-only setting edits. Reads do not trigger it. Windows infrastructure still has some additional overhead; PowerShell uses memory while the worker runs and exits afterward.

The worker compares a per-network configuration baseline, debounces edits, rechecks configuration and adapter identity before mutation, and requires three successful observations. The retry releases and reacquires only the selected adapter’s stale DHCP lease. Shared VMware DHCP may be restarted at most once per run; this briefly affects DHCP requests on other VMware networks. NAT is not restarted. Failed edits are recorded and acknowledged so later unrelated edits do not retry them. Queued duplicate events exit without overwriting the last meaningful result.

Normal timeout is about 90 seconds with a two-minute task limit. `Synced` verifies host IP/prefix, preferred address state, on-link route and required services; it does not prove guest SSH/DNS or every NAT rule works. Guest IPs, physical adapters and VMware configuration are not changed.

## Diagnostics and setup

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync.ps1 -Mode Check
```

Check mode is read-only. Exit codes: 0 synchronized/skipped, 2 needs attention, 1 error. Explicit administrator `-Mode Repair` inspects all eligible networks; the automatic task uses `-EventMode` to select only edited networks.

Installed code is in `%ProgramFiles%\VmnetSync`. `%ProgramData%\VmnetSync` retains a baseline, last result and pre-repair snapshot. A Ready task is waiting for an event. No result before the first edit is normal.

Setup enables system-wide File System and Registry success auditing and adds scoped SACLs. Other existing SACLs may also begin producing events. Uninstall removes tool-added rules and task but preserves global audit policies and diagnostics. Upgrade supports rollback and migration from 0.1.

## Development

```powershell
.\Test-Worker.ps1
.\Test-Setup.ps1
.\Test-Migration.ps1
.\Test-Renewal.ps1
.\Build.ps1
.\Test-Package.ps1
```

The automated suite includes 63 parser/worker checks, 11 setup checks, 4 legacy-name migration checks and 3 renewal-command checks. Separate real-network tests verified original VMware UI changes, stale-lease repair, a temporary custom network, opt-outs, real setup rollback, uninstall/reinstall and idle exit. Original networks were restored and the temporary adapter removed. The optional isolated integration test also passed real 4663/4657 → SYSTEM task → per-network check → exit and audit cleanup. See [architecture](docs/architecture.md), [troubleshooting](docs/troubleshooting.md) and [publishing](docs/publishing.md).

MIT licensed. Not affiliated with VMware. No VMware binaries or private host diagnostics are distributed.

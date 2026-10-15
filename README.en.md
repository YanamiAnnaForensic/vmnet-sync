# VMnet Sync

**Fix stale Windows host adapter addresses after VMware subnet changes. Check on configuration writes, repair eligible DHCP adapters, and exit without a resident synchronization process.**

[中文说明](README.md)

## What does this project do?

VMnet Sync is a VMware Workstation network helper for Windows. It addresses a specific problem: you save a new subnet in VMware's Virtual Network Editor, but the corresponding Windows host adapter keeps its old DHCP address. The host adapter and the virtual network can then end up on different subnets.

For example, you change VMnet8 from `192.168.56.0/24` to `192.168.36.0/24`, while its host adapter still has `192.168.56.1/24`. The tool reads VMware's saved configuration, identifies that adapter, requests a fresh DHCP address when automatic repair is supported, verifies its address, prefix and route, and exits. The actual address comes from VMware's configuration.

It supports NAT, host-only and custom VMnet0–19 networks, beyond VMnet8. Keep using VMware's original interface. Editing only VMnet1 does not cause an unchanged VMnet8 to be repaired.

## Why install it? Do I need it?

It is useful if you frequently change VMware subnets for labs, network teaching, development, testing or forensic simulations and have encountered host adapters that fail to follow those changes. Install it once to handle eligible stale DHCP addresses automatically, reducing repeated manual checks and renewals.

If your VMware host adapters already stay synchronized, you do not need to install it. It does not change static IPs inside guests, configure SSH or fix every connectivity problem. Automatic repair requires a connected host virtual adapter and VMware DHCP enabled in VMware. Disabled options and static Windows addresses are respected.

## Does it run or use memory while idle?

**There is no resident synchronization process or background polling.** Built-in Windows auditing and Task Scheduler receive configuration-write events and launch a worker only when one occurs.

| Action or state | Automatic synchronization |
|---|---|
| Normal computer use or running VMs without writing VMware network configuration | Does not start |
| Opening the editor or reading configuration | Does not proactively start |
| Saving configuration writes a monitored file or registry value | Starts a check; repairs eligible adapters if needed |
| Configuration matches or repair succeeds | Exits |
| Repair fails or times out | Records the result and exits within its time limit; no ongoing background retry |
| Boot, logon or installation completion | Does not independently trigger synchronization |
| VMware upgrades or Restore Defaults write monitored configuration | May also trigger a check |

The trigger is a **configuration write**, so it is not restricted to a person clicking Apply. Multiple events from one save may queue checks; checks with no configuration changes exit quickly. Manually opening setup or the status tool also briefly runs the corresponding program.

PowerShell and network modules use memory while the worker runs. Windows auditing and scheduling have some additional overhead. The measured idle state was `Ready`, with `0` running worker instances; this does not imply zero total system overhead. Normal synchronization has a roughly 90-second limit, with a separate two-minute task limit.

The helper uses built-in Windows components, requires one administrator installation and has no additional runtime download. **0.3.0 passed local real-network acceptance on Windows 11 build 26200 and Workstation 17.6.3.** Other versions still need compatibility testing. See [validation](docs/validation.md).

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

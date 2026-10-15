# VMnet8 Sync

An event-triggered helper for VMware Workstation on Windows. It checks whether the host VMnet8 adapter matches the NAT/DHCP configuration after a network configuration write, renews a stale DHCP lease when appropriate, and exits.

[中文说明](README.md)

## Use

1. Download the Windows x64 ZIP from Releases and extract the entire archive.
2. Double-click **Install.cmd** and accept the administrator prompt.
3. Change VMnet8 in VMware's Virtual Network Editor and click Apply as usual.

Use **Status.cmd** for installation/task status and **Uninstall.cmd** to remove the helper. Setup and the status window request administrator access. Re-running Install.cmd upgrades or repairs the installation.

There is no resident product process or service, boot/logon trigger, timer, or scheduled catch-up run. Installing does not launch a worker. Windows Event Log and Task Scheduler provide the trigger; they still do some additional work. The PowerShell worker uses memory while running and releases its process working set on exit.

## Compatibility and behavior

- Windows 10/11 x64, built-in Windows PowerShell 5.1; no extra runtime download.
- VMware Workstation, VMnet8 IPv4 NAT, DHCP-managed host virtual adapter.
- Configuration reads and administrator installation were verified with Workstation 17.6.3. Other versions need testing.
- Renamed Windows adapters are supported: the helper matches the VMware device description and MAC.
- It checks NAT/DHCP agreement, host IP/prefix, address state, on-link route and service status.
- Repair renews only VMnet8. A second attempt may restart the **shared VMware DHCP service**, briefly affecting DHCP requests on other VMware networks.
- It does not override static host configuration, change guest addresses, alter physical adapters or rewrite VMware files.
- A normal run is bounded to about 90 seconds, with a two-minute task limit. Multiple write events can queue bounded serial checks.

`Synced` means the configuration, host address and on-link route match and VMware services are running. It does not prove all NAT rules were loaded or that guest SSH/DNS works. This **0.1.0 preview** still needs real cross-subnet repair and wider event-sequence validation.

Setup enables system-wide File System success auditing and adds narrowly scoped SACL rules. Uninstall removes the tool-added rules and task but preserves the global audit policy, as other software may depend on it. Diagnostics remain in `%ProgramData%\Vmnet8Sync`; installed code is in `%ProgramFiles%\Vmnet8Sync`.

The first result file appears only after a configuration-change event. A Ready task is waiting for an event, not a resident worker. A historical read-only measurement took about 5 seconds and peaked near 155 MB; this is not a native low-memory executable.

## Development

```powershell
.\Test-Worker.ps1
.\Test-Setup.ps1
.\Build.ps1
```

Tests mock system mutation. The build produces Windows and source ZIPs plus SHA256SUMS.txt. CI runs on Windows; a matching `v<VERSION>` tag publishes a prerelease. See [publishing](docs/publishing.md), [architecture](docs/architecture.md) and [troubleshooting](docs/troubleshooting.md).

MIT licensed. Not affiliated with VMware. No VMware binaries or private host diagnostics are distributed.

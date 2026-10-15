# Changelog

## 0.2.0 — 2026-10-15 (preview)

- Discover configured VMnet0–19 from VMware registry flags; support host-only and custom NAT networks without assuming VMnet8, .1, .2 or /24.
- Compare a per-network configuration baseline and inspect only edited networks. Skip disconnected host adapters, bridges, unused slots and DHCP-off networks.
- Add Registry value-write auditing alongside configuration-file events, without a resident process, timer, startup check or installation-time repair.
- Isolate invalid networks, handle edits during a run and limit the shared DHCP restart to once per run.
- Preserve static addresses and disabled Windows adapters; record results per network. Acknowledge failed edits so unrelated future edits do not retry them.
- Migrate the 0.1 installation manifest and audit rules; create/recover baselines without starting a worker. Keep legacy task and directory names for upgrade compatibility.
- Add multi-network parsing, event-filter, worker and setup tests. Read-only inspection passed on the local Workstation 17.6.3 VMnet1 and VMnet8.
- Use native registry audit access with the required security privilege; propagate inherited SACLs to existing subkeys so registry-only edits actually produce events.
- Verify real 4663/4657 events, SYSTEM task execution, per-network checks and worker exit with isolated local fixtures; confirm configuration reads do not launch workers.
- Include an optional administrator integration test and verify inherited-rule cleanup and audit-policy restoration; explicitly disable auditing when restoring an originally disabled policy.

Real VMware Apply → cross-subnet DHCP renewal remains to be validated. The integration fixture preserved live adapter addresses and guarded service/network mutations.

## 0.1.0 — 2026-10-15

Initial preview of VMnet8 Sync for Windows and VMware Workstation.

- Double-click install, uninstall and status commands; automatic UAC elevation for setup.
- Windows event-triggered synchronization, with no product service, boot/logon trigger or timer.
- NAT/DHCP configuration validation, adapter identity checks and bounded retries.
- Targeted DHCP renewal, with one optional fallback restart of the shared VMware DHCP service.
- Repeat installation and upgrade with rollback; keep previous auditing rules and diagnostic data.
- Source and Windows release ZIPs, SHA-256 checksums and GitHub Actions validation.

Installation and event-rule registration were verified on Windows with Workstation 17.6.3.
Real cross-subnet repair and the full VMware event sequence still require broader validation.

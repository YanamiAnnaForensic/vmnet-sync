# VMnet Sync

**修复 VMware 改了子网、Windows 宿主机虚拟网卡却还停在旧网段的问题。保存配置时自动检查，完成后退出，无常驻同步进程。**

[English](README.en.md) · [工作原理](docs/architecture.md) · [故障排查](docs/troubleshooting.md) · [发布指南](docs/publishing.md)

VMnet Sync helps Windows host adapters catch up after VMware subnet changes. It runs on configuration writes and exits after checking or repairing the edited networks. [Read the English introduction →](README.en.md)

## 这个项目用来做什么？

VMnet Sync 是 Windows 上的 VMware Workstation 网络辅助工具。它处理一种具体问题：你已经在 VMware 虚拟网络编辑器里保存了新子网，但宿主机对应虚拟网卡仍使用旧的 DHCP 地址，导致宿主机和该虚拟网络不在同一网段。

例如，你把 VMnet8 从 `192.168.56.0/24` 改成 `192.168.36.0/24`，宿主机虚拟网卡却还保留 `192.168.56.1/24`。工具会读取 VMware 实际保存的配置，找到对应的宿主机网卡，在符合自动修复条件时重新申请 DHCP 地址，核对地址、掩码和路由，一致后退出。具体地址以 VMware 配置为准。

检查范围包括 NAT、仅主机和自定义 VMnet0–19，不限于 VMnet8。继续使用 VMware 原来的操作界面即可；一次只修改 VMnet1 时，工具不会顺带修复未变化的 VMnet8。

## 为什么要安装？我需要它吗？

如果你经常切换 VMware 子网，例如做实验环境、网络教学、开发测试或取证仿真，并且遇到过“VMware 已经改好，宿主机网卡还没跟上”，安装一次后可以自动处理这类旧 DHCP 地址问题，减少每次手动检查和续租。

如果你的 VMware 网络一直同步正常，就没有必要专门安装。它也不负责修改虚拟机内部的静态 IP、配置 SSH 或修复所有联网问题。自动修复需要在 VMware 中启用“将主机虚拟适配器连接到此网络”和 VMware DHCP；它不会替你打开已关闭的选项或覆盖 Windows 静态地址。

## 平时会不会运行、占内存？

**空闲时没有本工具常驻的同步进程，也没有后台轮询。** Windows 自带审计和任务调度负责接收配置写入事件，事件发生后才启动一次同步工作程序。

| 操作或状态 | 自动同步是否运行 |
|---|---|
| 正常使用电脑、运行虚拟机，没有写入 VMware 网络配置 | 不启动 |
| 只打开虚拟网络编辑器、查看配置 | 不主动启动 |
| 保存 VMware 网络配置，产生受监测的文件或注册表写入 | 自动启动一次检查；符合条件时修复 |
| 检查一致或修复成功 | 退出 |
| 无法修复或超时 | 记录结果并限时退出，不持续后台重试 |
| 开机、登录、安装完成 | 不单独触发同步 |
| VMware 升级或“恢复默认网络”写入了受监测的配置 | 也可能触发一次检查 |

它依据**配置写入事件**触发，不能限定为只有手动点击“应用”才触发。一次保存产生多个事件时，后续无配置变化的检查会快速退出。手动打开安装器或状态工具也会短暂运行相应程序。

工作程序执行时，PowerShell 和网络模块会短暂占用内存；Windows 原有的审计和任务调度也有少量额外开销。实测空闲状态为 `Ready / 就绪`、运行实例 `0`，不表示整个系统的额外开销为零。正常同步流程约有 90 秒时限，任务另有两分钟上限。

这是独立辅助工具，使用 Windows 自带组件，需要一次管理员安装，无额外运行库下载。0.3.0 已完成本机实网验收，其他 Windows/VMware 版本的兼容性仍按预览版提供。详见[验证记录](docs/validation.md)。

## 快速开始

1. 从 [GitHub Releases](https://github.com/YanamiAnnaForensic/vmnet-sync/releases) 下载并解压 `vmnet-sync-0.3.0-windows-x64.zip`。
2. 双击 **Install.cmd** 并接受 UAC。已有 0.1/0.2 时，同一入口会升级，并迁移旧任务、程序目录及诊断数据。
3. 照常进入 VMware 的“编辑 → 虚拟网络编辑器”，修改目标网络并点击“应用”。

| 入口 | 功能 |
|---|---|
| `Install.cmd` | 安装、重复安装、升级；自动申请管理员权限 |
| `Status.cmd` | 查看版本、任务、运行实例数和最近同步结果 |
| `Uninstall.cmd` | 删除自动任务、程序及新增审计规则，保留诊断数据 |

安装后无需保留解压目录。程序位于 `%ProgramFiles%\VmnetSync`，数据位于 `%ProgramData%\VmnetSync`，任务名为 `VmnetSync-AfterConfigWrite`。旧 `Vmnet8Sync` 安装在成功升级后移除；迁移失败会回滚。

## 支持范围

| 网络或状态 | 行为 |
|---|---|
| NAT，包括配置在自定义 VMnet 上的 NAT | 核对 NAT、DHCP、注册表及实际网卡，再定向续租 |
| VMnet1 等仅主机网络 | 核对 DHCP、注册表及实际网卡；不要求 NAT 服务运行 |
| 自定义 VMnet0–19 | 按配置发现，需启用宿主机连接和 VMware DHCP |
| 取消“将主机虚拟适配器连接到此网络” | 跳过，不新建或启用网卡 |
| 桥接、未使用的网络占位项 | 跳过 |
| VMware DHCP 关闭 | 报告跳过；不推测缺失的地址、掩码或改为 DHCP |
| Windows 网卡静态配置 | 可检查已有配置；不覆盖不一致的静态地址 |
| 网卡禁用、缺失、MAC 不符或有默认路由 | 报告需要处理，不强制修复 |

支持 Windows 10/11 x64、Windows PowerShell 5.1。已在 Windows 11 build 26200、Workstation 17.6.3 上验证 VMnet1/8 和自定义 VMnet3；其他 Windows/VMware 版本仍需兼容性验证。支持重命名后的 Windows 网卡、非 /24 子网，以及非固定 .1/.2 的宿主机和网关地址。不修改客体系统 IP、物理网卡、IPv6 或 VMware 配置文件。

## 何时运行

没有产品常驻进程、后台服务、定时检查、开机/登录检查或安装时修复。Windows 的文件/注册表审计事件交由任务调度器启动一次工作程序。只打开编辑器、只读查询状态、安装完成，都不主动启动同步。

空闲时没有本工具进程的工作集；Windows 原有的事件日志和任务调度器仍有少量额外工作。执行期间 PowerShell 和网络模块会短暂占用内存，完成后退出。任务显示 **Ready / 就绪** 只是等待事件。

安装只保存配置基线，不读取或修改实际网卡。一次修改后，按各个 VMnet 的指纹选择发生变化的网络；例如仅修改 VMnet1 时，即使 VMnet8 原本存在旧地址，也不会顺带修复 VMnet8。失败的修改同样会记录并确认基线，不因以后修改其他网络再次尝试。需要重新尝试时，针对该网络重新应用实际变更，或由管理员明确运行手动修复。

多个写入事件可能串行排队；配置未变化的后续运行会快速退出，并保留上次有意义的结果。正常流程最多约 90 秒，任务另有两分钟上限。

## 修复和结果

先对目标网卡执行 `ipconfig /renew "实际网卡名称"`。仍不同步时，每轮最多重启一次共享的 **VMnetDHCP** 服务，然后仅对目标网卡释放旧 DHCP 租约并重新申请。共享服务重启会短暂影响其他 VMware 网络的 DHCP 请求。不会重启 NAT 服务。

每个网络需要连续三次验证地址、掩码、地址状态、直连路由及所需服务都正确，才报告 `Synced`。这不证明客体 SSH、DNS 或所有 NAT 转发规则可用。单个网络配置错误不会阻止其他已变更且有效的网络处理。

双击 `Status.cmd` 查看最近结果，或执行只读检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync.ps1 -Mode Check
```

`Check` 不续租、不写基线或结果文件。退出码：`0` 为一致/跳过，`2` 为需要处理，`1` 为检查错误。管理员可明确运行 `-Mode Repair` 来检查并修复所有符合条件的网络；自动任务额外使用 `-EventMode`，仅处理配置发生变化的网络。

`%ProgramData%\VmnetSync` 保存 `baseline.json`、`last-result.json` 和 `before-repair.json`，仅保留最近数据。安装后没有结果文件属正常情况。

## 安装和卸载

安装会将代码复制到管理员/SYSTEM 可写的受保护目录，开启 Windows“文件系统”和“注册表”成功审计；为两份配置文件、配置目录和 VMware VMnetConfig 注册表树添加窄范围审计规则，再注册事件任务。注册表读取和文件读取不触发任务。

这些审计开关是系统级设置，也可能使其他已有审计规则的对象开始记录事件。卸载移除本工具新增的规则和自动任务，保留全局审计策略以免影响其他工具。诊断文件保留，不会产生后台活动。升级失败会尝试恢复程序、任务、基线和本轮审计变更。

## 开发

在 Windows PowerShell 5.1 运行：

```powershell
.\Test-Worker.ps1
.\Test-Setup.ps1
.\Test-Migration.ps1
.\Test-Renewal.ps1
.\Build.ps1
.\Test-Package.ps1
```

自动测试覆盖 63 项解析/工作流程、11 项安装、4 项旧名迁移和 3 项续租命令行为。另完成真实 VMware 原界面跨子网应用、旧租约复现与实际修复、自定义网络创建/修改/退出、宿主机连接与 DHCP 开关、安装升级回滚和卸载重装验收；隔离配置的 4663/4657 事件链验证也已通过。实际测试后的原网络已恢复，临时网卡已移除。详见[验证记录与复现方法](docs/validation.md)。

MIT 许可。VMware 商标属于权利人，本工具与 VMware 官方无隶属关系，不附带 VMware 文件。

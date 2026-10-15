# VMnet8 Sync

**修改 VMware NAT 网络后，自动同步 Windows 宿主机的 VMnet8 地址。只在配置写入时运行，完成后退出。**

[English](README.en.md) · [工作原理](docs/architecture.md) · [故障排查](docs/troubleshooting.md) · [发布指南](docs/publishing.md)

有时 VMware 虚拟网络编辑器已切换到新子网，宿主机的 VMnet8 却还保留旧 DHCP 地址，导致无法访问新网段的虚拟机。VMnet8 Sync 会检查这个差异，定向续租并复核结果。

这是适用于 VMware Workstation 的独立辅助工具，需要一次管理员安装。使用 Windows 自带组件，不需要 Python、PowerShell 7、.NET SDK 或额外下载。

## 快速开始

1. 下载 Release 中的 **`vmnet8-sync-0.1.0-windows-x64.zip`**，完整解压到本地文件夹。
2. 双击 **`Install.cmd`**，在 Windows UAC 提示中选择“是”，等待安装完成提示。
3. 照常进入 VMware 的 **编辑 → 虚拟网络编辑器 → VMnet8**，修改配置并点击“应用”。

安装完成后不需要保留解压目录，运行文件已经复制到 `%ProgramFiles%\Vmnet8Sync`。需要卸载或查看状态时，可保留原压缩包。

| 入口 | 功能 |
|---|---|
| `Install.cmd` | 安装、重复安装或升级；自动申请管理员权限 |
| `Status.cmd` | 弹窗显示安装版本、任务状态、运行实例数和最近结果；需要管理员权限读取 SYSTEM 任务 |
| `Uninstall.cmd` | 卸载自动任务及程序文件，保留最近诊断记录 |

下载 ZIP 后应先解压全部文件。若 Windows 或组织策略阻止运行脚本，请参阅[故障排查](docs/troubleshooting.md)。

## 何时运行

**安装后、开机、登录和空闲时都不会主动启动同步程序。**

工具仅注册一个 Windows 事件触发任务。VMware 网络配置被写入后，Windows 启动一次后台检查；状态连续一致时退出，无法修复时也会超时退出。

- 没有产品常驻进程、托盘程序或产品后台服务。
- 没有定时检查、开机触发、登录触发或唤醒电脑。
- 空闲时没有本工具的进程工作集；Windows 自带事件日志、任务调度仍承担少量额外工作。
- 运行时会短暂占用内存。早期版本一次只读检查约 5 秒，观测峰值约 155 MB，不能把它理解为运行期间零内存。

任务显示“就绪 / Ready”表示等待系统事件，并不表示同步程序一直运行。一次应用可能产生多个写入事件，后续检查会串行执行，均有时间上限。

## 支持范围

| 项目 | 支持情况 |
|---|---|
| 操作系统 | Windows 10 / 11，64 位；使用 Windows PowerShell 5.1 |
| VMware | Workstation；已验证 17.6.3 的配置读取与管理员安装，其他版本需兼容性验证 |
| 目标网络 | VMnet8、IPv4 NAT、DHCP 管理的宿主机虚拟网卡 |
| 网卡改名 | 支持；按 VMware 设备描述定位并核对 MAC |
| 修复方式 | 仅对 VMnet8 续租，必要时最多重启一次 VMware DHCP 服务后重试 |
| 静态地址 | 可以检查一致性；不自动覆盖手动配置 |
| 虚拟机内部 IP | 不修改；客体系统需要单独配置 |

`VMnetDHCP` 是 VMware 多个虚拟网络共享的服务，第二次尝试时重启它会短暂影响这些网络的 DHCP 请求。工具不会重启 NAT 服务、改写 VMware 配置或修改物理网卡。

`Synced` 表示 VMware 配置与宿主机实际地址、掩码、直连路由一致，相关服务正在运行；不代表客体 SSH、DNS 或全部 NAT 转发规则已经完成验证。

## 状态和日志

双击 `Status.cmd` 可查看状态。也可以只读检查当前网络：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync.ps1 -Mode Check
```

该命令不会续租或修复。退出码 `0` 为一致，`2` 为需要处理，`1` 为检查出错。

自动执行结果位于 `%ProgramData%\Vmnet8Sync\last-result.json`；修复前状态位于同目录的 `before-repair.json`。仅保留最近结果，不无限追加日志。首次配置修改前没有结果文件是正常的。

## 安装做了什么

安装将运行文件复制到受权限保护的系统目录，启用 Windows“文件系统”成功审计，为两份 VMware 配置文件及其目录设置审计规则，再注册 SYSTEM 身份的 `Vmnet8Sync-AfterConfigWrite` 任务。读取配置不会触发任务。

文件系统审计是系统级设置：系统中其他已有审计规则的文件也可能开始记录事件。卸载会移除本工具新增的规则；全局审计开关保持当前值，避免影响其他工具或组策略。

可以重复执行 `Install.cmd` 来升级或恢复安装。工具会等待当前工作结束，保存旧程序与任务，并在安装失败时尝试恢复；不会为验证安装而启动同步程序。

## 卸载

双击 **`Uninstall.cmd`** 并接受 UAC。卸载会等待当前工作结束，删除自动任务、已知程序文件和本工具增加的审计权限位。保留 `%ProgramData%\Vmnet8Sync` 中的诊断数据，便于检查问题；它不会导致程序继续运行。

## 开发与发布

在 Windows PowerShell 5.1 中运行：

```powershell
.\Test-Worker.ps1
.\Test-Setup.ps1
.\Build.ps1
```

测试覆盖配置校验、事件过滤、同步流程、超时退出、安装与升级回滚。系统操作使用模拟，测试文件限于临时目录。`Build.ps1` 生成 Windows 用户包、完整源码包和 SHA-256 校验文件。GitHub Actions 会在推送和 PR 时验证；推送与 `VERSION` 一致的 `v0.1.0` 标签后生成预发布 Release。

发布前请阅读[发布指南](docs/publishing.md)，其中列出了实际验证范围及尚待完成的端到端验收。当前版本作为 **0.1.0 预览版**分发，真实跨子网修复和不同 VMware 版本的事件序列尚需验证。

本项目按 [MIT License](LICENSE) 开源。VMware 商标属于其权利人；本工具与 VMware 官方无隶属关系，不附带 VMware 文件。

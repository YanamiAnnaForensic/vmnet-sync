# 打包与发布

**0.3.0 已完成[本机实网验收](validation.md)，以预览版发布。每个发布提交还必须通过 GitHub Actions；其他 Windows/VMware 版本不能宣称已验证。**

## 本地验证和打包

在 Windows PowerShell 5.1 运行：

```powershell
.\Test-Worker.ps1
.\Test-Setup.ps1
.\Test-Migration.ps1
.\Test-Renewal.ps1
.\Build.ps1
.\Test-Package.ps1
```

生成：

- `vmnet-sync-0.3.0-windows-x64.zip`：完整解压后双击 Install.cmd。
- `vmnet-sync-0.3.0-source.zip`：完整源码、文档、测试及隐藏的 GitHub 工作流。
- `SHA256SUMS.txt`：两个包的 SHA-256 校验。

包内顶层目录为 vmnet-sync-0.3.0。源码包为独立项目，用户包无需额外下载运行库。构建使用文件白名单；不包含本机配置、安装清单、基线、网络状态、凭据、检材或个人截图。

## 当前验证范围

配置解析覆盖 VMnet1、VMnet8、自定义 NAT、非固定 IP/前缀、关闭 DHCP/宿主机连接、桥接/占位项、无效网络隔离和重叠子网。事件过滤通过 Windows Event Log 查询解析和 Task Scheduler 定义解析，未注册测试任务。

工作流程使用模拟的 Windows 网络、服务及数据保存操作，覆盖独立变更、多网络变更、队列重复、运行中变更、共享 DHCP 重试、失败后不意外重试和有界退出。安装测试只操作临时目录并模拟系统 API，覆盖从 0.1 升级、回滚、清单校验、基线恢复与卸载。

源码中的 Test-Integration.ps1 可在已安装 VMware、VMnet1/VMnet8 状态一致的本地管理员 PowerShell 中单独运行。它建立隔离配置和临时 SYSTEM 任务，临时开启审计后恢复，不修改实际网卡或重启服务；默认报告写入系统临时目录。CI 不运行这个需要 VMware 和管理员权限的集成测试。

Windows 11 build 26200/Workstation 17.6.3 实网验收已完成：VMnet1/8 的原界面跨子网修改与真实旧租约修复、自定义 VMnet3 的 /23 修改、宿主机连接/DHCP 开关、无额外网卡修复、工作进程退出、真实升级失败回滚及卸载重装。原网络已恢复，临时网卡已移除。另完成隔离文件/注册表的真实 4663/4657 事件链及审计恢复验证。

## 在其他版本上复验

在测试机安装用户包，确认无额外工作进程。分别修改 VMnet1、VMnet8、自定义 NAT/仅主机网络；验证 Security 文件/注册表事件 → SYSTEM 任务 → 正确网卡续租 → 退出。验证只修改一张时不会操作另一张、关闭宿主机连接/DHCP 不被自动恢复、重新安装和卸载完整清理。检查共享 DHCP 重启影响及读取/空闲/开机/登录均不额外触发。

注册表路径、键名大小写、保存进程和 VMware 版本差异仍需兼容性测试。全局审计可能受组策略影响。

## 标签与预发布

仓库根需包含全部源码及 .github。工作流推送/PR 时测试并打包，匹配 VERSION 的 v<VERSION> 标签会在验证后生成 prerelease。workflow_dispatch 只生成构建 artifact。

源码上传不改变仓库可见性，也不自动创建版本标签或 Release。保留预览标记并如实更新验证范围；需要创建预发布时，推送与 VERSION 一致的标签即可触发 release.yml。不要将本机配置、验证日志或诊断数据加入仓库。

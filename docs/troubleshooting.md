# 故障排查

## 安装与升级

先完整解压 ZIP，再运行 Install.cmd 并接受 UAC。若 Windows 因下载标记阻止脚本，请确认来源后解除 ZIP 锁定、重新解压。AppLocker、WDAC 或组策略仍可能阻止脚本/审计，需要按本机策略处理。

安装只建立配置基线，不修复已有不一致，也不启动工作进程。安装期间不要同时点 VMware“应用”。VMware 升级改变安装路径后，重跑 Install.cmd 以刷新保存进程过滤。重复安装支持从 0.1/0.2 迁移旧 Vmnet8Sync 名称和数据、更新指纹格式、恢复损坏基线；不会自动执行修复。

## Ready、没有结果或访问被拒绝

Ready / 就绪表示等待事件；不是常驻运行。首次修改前没有 last-result.json 正常。Status.cmd 请求管理员权限以读取 SYSTEM 任务，普通终端可能无权读取，会明确报告无法检查。

## 修改后没有同步

1. 在 VMware 原虚拟网络编辑器修改目标网络并应用。
2. 等待任务退出，用 Status.cmd 查看 Networks 中该 VMnet 的结果及 Reason。
3. 若没有运行结果，管理员终端检查事件任务和两类成功审计：

```powershell
Get-ScheduledTask -TaskName 'VmnetSync-AfterConfigWrite'
Get-ScheduledTaskInfo -TaskName 'VmnetSync-AfterConfigWrite'
auditpol.exe /get /subcategory:'{0cce921d-69ae-11d9-bed3-505054503030}'
auditpol.exe /get /subcategory:'{0cce921e-69ae-11d9-bed3-505054503030}'
```

`Skipped` 常见原因：未连接宿主机虚拟网卡、关闭 VMware DHCP、桥接或未使用网络。工具不会擅自恢复这些选项。

`NeedsAttention` 常见原因：静态地址、禁用或缺失网卡、MAC 不符、默认路由、重叠子网、配置尚未一致、所需服务未运行。仅主机网络只依赖 DHCP 服务，NAT 网络同时要求 NAT 服务运行。

修改 VMnet1 不会顺带检查未变化的 VMnet8。失败变更会被记录并确认基线，因此后续修改其他网络不会重试旧失败。可以只读查看全部网络：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync.ps1 -Mode Check
```

若管理员明确决定修复所有符合条件的网络，可运行同一命令加 `-Mode Repair`（替换 Check）。它会定向续租，必要时短暂重启共享 VMware DHCP，再仅对目标网卡释放旧租约并重新申请；不会覆盖静态地址。自动运行只处理发生变化的网络。

## IP 一致但仍无法连接客体

Synced 只验证宿主机配置、网卡、路由和所需服务。还需确认客体接入正确 VMnet，客体 IP 已进入相同子网，SSH 监听和防火墙正常。工具不修改检材中的静态 IP。

## 卸载和问题反馈

卸载后最近诊断和基线保留在 ProgramData\VmnetSync，不产生后台活动。全局文件系统/注册表审计策略保留；新增 SACL 和自动任务移除。程序目录中的未知文件也保留。

反馈请注明 Windows/VMware/工具版本、受影响 VMnet、网络模式、DHCP/宿主机连接状态和复现步骤。公开前清除私有 IP、MAC、用户名、路径和截图中的敏感信息。


## 编辑器提示子网 IP 和掩码不匹配

先看弹窗指出的是哪个 VMnet；添加 VMnet3 时，也可能因 VMnet1 的旧设置而被拒绝。网络地址必须与掩码对齐，例如 `192.168.93.0/23` 无效，正确的 /23 网络地址是 `192.168.92.0`。若原本需要 `192.168.93.0/24`，应在原编辑器将该网络掩码改为 `255.255.255.0` 再应用。

保存前即被编辑器拒绝时，工具无法代替一次成功保存。若保存后注册表与 DHCP 文件的掩码仍不一致，工具会报告需要处理并停止对该网卡修复，避免按互相矛盾的配置续租。测试/手动恢复配置时应同时核对文件、注册表、Windows 地址前缀与路由。

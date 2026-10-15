# 故障排查

## 双击没有安装成功

先完整解压 ZIP，再运行 `Install.cmd` 并接受 UAC。脚本路径含空格或中文可以正常使用。安装不需要下载额外依赖。

若文件带有 Internet 下载标记，且 Windows 阻止执行，可在确认来源后右键 ZIP → 属性 → 解除锁定，再重新解压。组织的 AppLocker、WDAC 或组策略仍可能阻止脚本或覆盖审计策略，需要管理员按本机策略处理。工具不会永久修改全局 PowerShell ExecutionPolicy。

失败时对话框会显示原因。需要完整错误位置时，在管理员 Windows PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

## 显示 Ready / 就绪

这是正常状态：Windows 正在等待配置写入事件，产品工作程序没有运行。首次配置修改前不存在 `last-result.json` 也是正常的。安装完成不会进行额外修复。

## 状态查看提示拒绝访问

`Status.cmd` 会自动请求管理员权限以读取 SYSTEM 任务。直接执行 `Status.ps1` 时可用普通权限，但 Windows 可能拒绝读取该任务；此时会明确显示未能检查任务，不会假称没有运行实例。可在管理员终端重新运行。

## 修改后仍不同步

1. 用 VMware 网络编辑器修改 VMnet8 并点“应用”。只打开窗口或取消修改不会触发。
2. 等待当前任务退出，再查看 `Status.cmd` 中最近状态。
3. 若没有最近结果，在管理员终端检查任务及文件系统审计：

```powershell
Get-ScheduledTask -TaskName 'Vmnet8Sync-AfterConfigWrite'
Get-ScheduledTaskInfo -TaskName 'Vmnet8Sync-AfterConfigWrite'
auditpol.exe /get /subcategory:'{0cce921d-69ae-11d9-bed3-505054503030}'
```

可以重复运行 `Install.cmd` 刷新代码、任务和审计规则。VMware 升级改变了安装路径后，也需要重新安装本工具来更新进程路径过滤。

`NeedsAttention` 的 `Reason` 会指出阻塞原因，例如静态地址、网卡禁用、MAC 不匹配、配置文件尚不一致或服务未运行。工具只自动处理 DHCP 管理的宿主机 VMnet8，不把手动静态设置改成 DHCP。

## 地址一致但 SSH 连不上

`Synced` 只验证宿主机与 VMware 配置。仍需确认虚拟机网卡接入 VMnet8、客体 IP 与新子网一致、SSH 监听地址和防火墙规则正确。客体镜像中的原静态 IP 不会被本工具修改。

## 卸载后仍有文件

最近诊断数据保留在 `%ProgramData%\Vmnet8Sync`，不会产生后台活动。卸载后的系统文件审计开关保持原值，新增文件审计规则已移除。如果程序目录中存在其他未知文件，卸载也会保留它们。

## 提交问题

提供 Windows、VMware 和本工具版本、复现步骤及最近状态。提交公开 issue 前清除诊断中的私有 IP、MAC、用户名和文件路径。源码包和用户发行包不携带本机运行结果。

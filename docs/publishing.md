# 上传 GitHub 与发布

## 第一次上传

源码 ZIP 是完整独立项目，不依赖原来的工作区。

1. 解压 `vmnet8-sync-0.1.0-source.zip`。
2. 在 GitHub 创建仓库，建议名为 `vmnet8-sync`。
3. 把解压后的**项目目录里的全部内容**上传到仓库根目录，包括 `.github`、`.gitignore` 和 `.gitattributes`。
4. 仓库首页会使用 `README.md`。默认附带 MIT 许可证，可以在发布前根据自己的需求调整。

也可以在解压后的项目目录使用 Git：

```powershell
git init
git add .
git commit -m "Initial release of VMnet8 Sync"
git branch -M main
# 将下面的地址替换为你创建的仓库地址。
git remote add origin https://github.com/YOUR-NAME/vmnet8-sync.git
git push -u origin main
```

## 发布给普通用户

在 GitHub Releases 中创建版本 `v0.1.0`，勾选预发布，上传：

- `vmnet8-sync-0.1.0-windows-x64.zip`：普通用户下载并双击安装。
- `vmnet8-sync-0.1.0-source.zip`：包含测试、打包脚本和工作流的完整源码。
- `SHA256SUMS.txt`：两个 ZIP 的 SHA-256 校验值。

本地包均含一个 `vmnet8-sync-0.1.0` 顶层目录。不要上传自己系统中的 `installation.json`、`last-result.json`、网卡配置、检材、安装日志或个人截图。

## 自动发布

工作流在推送和 PR 时运行只读/模拟测试、生成 ZIP 并上传为工作流 artifact。它不在 CI 安装 VMware，也不执行真实网络修复。

本地或 CI 都可以用 Windows PowerShell 5.1 执行：

```powershell
.\Test-Worker.ps1
.\Test-Setup.ps1
.\Build.ps1
.\Test-Package.ps1
```

版本号来自 `VERSION`。更新版本号和 CHANGELOG 后推送同名版本标签：

```powershell
git tag v0.1.0
git push origin v0.1.0
```

标签需与 `VERSION` 一致。`release.yml` 会测试、打包并使用仓库自带 `GITHUB_TOKEN` 发布一个 **prerelease**；不需要添加个人访问令牌。仓库若禁用了 Actions 写权限，需要由仓库管理员允许工作流发布 Release。手动 `workflow_dispatch` 只生成 artifact，不自动发布标签。

## 当前验证范围

- 配置解析、网卡身份、路由、事件过滤及 Windows 对事件查询/任务 XML 的解析。
- 模拟的成功修复、已一致退出、过期配置取消及超时退出。
- 临时目录中的模拟安装、重复安装、升级回滚、卸载与重新安装。
- 在 Windows 与 Workstation 17.6.3 上验证过早期版本的管理员安装、SACL 和任务注册；确认安装不启动工作程序。
- 双击入口使用系统 PowerShell，安装与状态查看会申请 UAC。系统修复操作在自动化测试中使用模拟。

仍需在测试机完成：真实 VMware Apply → Security 事件 → SYSTEM 任务 → 跨子网续租 → 成功退出，以及不同 VMware/Windows 版本的兼容性。安装注册成功不等于这些端到端场景全部通过，因此首版以预览版发布。

## 发布验收

在测试机解压用户包，安装后确认没有工作进程；修改网络并应用后确认自动执行和退出；再次安装、卸载、重新安装；确保未修改配置的开机、登录和空闲过程不触发额外工作程序。检查共享 DHCP 服务第二次尝试的短暂影响，及物理网卡和默认路由未被更改。

# 3ds Max 插件发布仓库

此仓库是 GitHub 外网发布的本地工作副本。本机目录固定为：

```text
D:\Tes\MBB\3dsMaxPluginLibrary
```

构建产物统一来自：

```text
D:\Tes\MBB\bundle-repository
```

GitHub 与公司内网是两个完全独立的发布通道：

```text
bundle-repository → 本地 Git 克隆 → GitHub
bundle-repository → 公司 UNC 仓库
```

GitHub 发布不访问公司 UNC，公司发布不访问 GitHub，也不执行 Git 命令。需要
同时发布时，必须分别执行两个命令。

## 仓库结构

```text
catalog.ini     子插件清单
packages/       子插件版本化 Bundle ZIP
manager.ini     插件管理器独立更新清单
manager/        插件管理器版本化 Bundle ZIP
tools/          双通道发布、校验和回归测试脚本
```

同一个版本号对应的 ZIP 内容必须保持不变。内容变化时必须提升插件版本，
不能覆盖已经发布的同版本包。

## 发布前校验

```powershell
.\tools\Test-PluginRepository.ps1
```

只有校验通过后才允许发布。

## GitHub 外网发布

脚本从 `bundle-repository` 复制本次选定的包和清单条目，只暂存明确文件，
然后校验、提交并推送 `main`。脚本不会访问公司仓库，也不会执行
`git add -A`。

```powershell
.\tools\Publish-GitHub.ps1 `
  -CommitMessage "Publish jx-qachar v1.0.3" `
  -PluginIds "jx-qachar"
```

发布管理器：

```powershell
.\tools\Publish-GitHub.ps1 `
  -CommitMessage "Publish CompanyPluginManager v0.7.24" `
  -PublishManager
```

下架插件只删除 GitHub 清单条目，不删除历史包：

```powershell
.\tools\Publish-GitHub.ps1 `
  -CommitMessage "Delist old-plugin" `
  -RemovePluginIds "old-plugin"
```

只有明确需要让 GitHub 子插件清单与构建仓库完全一致时，才使用
`-PublishFullCatalog`。

## 公司内网直发

公司发布直接从构建仓库复制到 UNC，不读取本地 Git 提交，也不访问 GitHub：

```powershell
.\tools\Publish-CompanyDirect.ps1 `
  -PluginIds "jx-qachar"
```

默认公司仓库：

```text
\\10.15.128.222\角色模型\Tool\3dsMaxPluginLibrary
```

内网发布同样支持 `-RemovePluginIds`、`-PublishManager` 和
`-PublishFullCatalog`。脚本先备份清单、复制版本化包，再原子切换元数据并
复验；失败时恢复清单。远端已存在但哈希不同的同名包会阻止发布，历史包
不会自动删除。

## 动作选择

- `-PluginIds`：只发布指定子插件，可传多个 ID。
- `-RemovePluginIds`：只下架指定子插件，可传多个 ID。
- `-PublishManager`：发布 `manager.ini` 与管理器包。
- `-PublishFullCatalog`：完整替换子插件清单，不能与前两项组合。

每次至少指定一种动作。`PluginIds` 与 `RemovePluginIds` 不能包含同一个 ID。

## 回归测试

测试只使用系统临时目录和本地裸 Git 远端，不访问真实 GitHub 或公司 UNC：

```powershell
.\tools\tests\Test-PublishingWorkflow.ps1
```

发布备份和 `release.json` 记录保存在
`D:\Tes\MBB\publication-backups\company` 或 `github`。

# 3ds Max 插件发布仓库

此仓库是公司 3ds Max 插件的唯一发布源。本机发布目录固定为：

```text
D:\Tes\MBB\3dsMaxPluginLibrary
```

正式流程：

```text
插件工程构建
  → 将待发布清单和 Bundle 放入本仓库
  → 完整校验
  → 提交并推送 GitHub main
  → 从 origin/main 的干净快照同步公司仓库
  → 再次校验公司仓库
```

公司仓库不再直接接收开发目录或未提交文件。

## 仓库结构

```text
catalog.ini     子插件清单
packages/       子插件版本化 Bundle ZIP
manager.ini     插件管理器独立更新清单
manager/        插件管理器版本化 Bundle ZIP
tools/          发布、校验和公司镜像脚本
```

同一个版本号对应的 ZIP 内容必须保持不变。内容变化时必须提升插件版本，
不能覆盖已经发布的同版本包。

## 发布前校验

```powershell
.\tools\Test-PluginRepository.ps1
```

只有校验通过后才允许发布。

## GitHub-first 一键发布

必须明确列出本次需要提交的文件，脚本不会执行 `git add -A`：

```powershell
.\tools\Publish-GitHubFirst.ps1 `
  -CommitMessage "Publish CompanyPluginManager v0.7.17" `
  -PublishPaths @(
    "manager.ini",
    "manager/CompanyPluginManager_v0.7.17.bundle.zip"
  )
```

脚本会：

1. 确认当前分支是 `main`，并且本机没有落后于 `origin/main`；
2. 只暂存 `PublishPaths` 指定的文件；
3. 提交后从该提交导出干净快照并校验；
4. 直接推送 GitHub `main`；
5. 重新获取 `origin/main`，再同步公司仓库；
6. 最后验证公司仓库。

## 只验证 GitHub 远端快照

不会写入公司仓库：

```powershell
.\tools\Sync-CompanyMirror.ps1 -ValidateOnly
```

## 公司镜像

默认公司仓库：

```text
\\10.15.128.222\角色模型\Tool\3dsMaxPluginLibrary
```

同步脚本只复制清单引用到的版本化包，并在包全部就绪后更新
`catalog.ini` 和 `manager.ini`。远端已存在但哈希不同的同版本包会阻止发布。
现有未引用文件不会自动删除。

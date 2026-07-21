# Codex Windows → Windows 一键迁移使用方法

本方法使用两个自包含 BAT，把旧电脑的 Codex 对话、项目记录、Skills、Plugins、记忆和本地索引迁移到新电脑。

## 文件说明

- `01_旧电脑_一键打包.bat`：在旧电脑生成迁移 ZIP。
- `02_新电脑_一键部署.bat`：在新电脑备份当前环境、恢复数据、修正路径并重新注册项目。

## 一、环境要求

旧电脑需要：

- Windows 10 或 Windows 11。
- Codex Desktop 已经正常使用过。
- 存在 `%USERPROFILE%\.codex`。
- 打包期间有足够磁盘空间。

新电脑需要：

- Windows 10 或 Windows 11。
- 已安装 Codex Desktop。
- 已启动并登录过一次 Codex。
- Python 3，并且能够使用标准库 `sqlite3`。

检查 Python：

```powershell
python -c "import sqlite3; print(sqlite3.sqlite_version)"
```

如果使用 Python Launcher，也可以检查：

```powershell
py -3 -c "import sqlite3; print(sqlite3.sqlite_version)"
```

通常不需要管理员权限，也不需要永久修改 PowerShell 执行策略。

## 二、旧电脑打包

1. 把两个 BAT 复制到旧电脑的 Codex 数据目录：

```text
C:\Users\旧用户名\.codex
```

2. 完全退出 Codex。确认任务管理器中没有仍在运行的 Codex 进程。
3. 双击：

```text
01_旧电脑_一键打包.bat
```

4. 等待完成。成功后会在当前 `.codex` 目录生成：

```text
Codex-Windows-Migration-日期时间.zip
```

5. 保存这个 ZIP。不要把它上传到公开仓库或公开网盘链接。

打包内容主要包括：

- `sessions` 和 `archived_sessions`
- `session_index.jsonl`
- `state_*.sqlite`
- memories 和 goals 数据库
- Skills、Plugins、Rules 和相关本地数据
- 项目路径及对话归属信息

默认排除：

- `auth.json` 和其他登录凭据
- `config.toml`
- Cookies、浏览器登录状态
- 日志和运行时缓存
- SQLite WAL/SHM 临时文件
- `.codex` 外部的项目源码

## 三、传输迁移包

把以下文件传到新电脑：

```text
Codex-Windows-Migration-日期时间.zip
01_旧电脑_一键打包.bat
02_新电脑_一键部署.bat
```

可以使用移动硬盘、局域网、私人网盘或其他可信渠道。

## 四、新电脑部署

1. 在新电脑安装 Codex Desktop。
2. 启动 Codex并完成登录。
3. 登录成功后完全退出 Codex。
4. 把迁移 ZIP 和两个 BAT 放入新电脑的：

```text
C:\Users\新用户名\.codex
```

5. 双击：

```text
02_新电脑_一键部署.bat
```

6. 等待脚本完成。部署过程中会自动：

- 校验 ZIP 中每个文件的 SHA-256。
- 备份新电脑当前 `.codex`。
- 合并普通对话和归档对话。
- 合并 `session_index.jsonl`。
- 合并 `state_*.sqlite` 的线程记录。
- 修正 `cwd`、`workspace_roots` 和 `rollout_path`。
- 保留新电脑的登录状态、`config.toml` 和安装身份。
- 检查 SQLite 数据库完整性。
- 创建缺失的空项目目录。
- 尝试通过 `codex app <项目路径>` 向 Codex 注册项目。

部署前备份保存在新用户目录下：

```text
C:\Users\新用户名\.codex-backup-before-migration-日期时间
```

在确认迁移完整之前，不要删除这个备份，也不要删除旧电脑的数据。

## 五、不同用户名

新旧电脑用户名不需要一致。

例如：

```text
旧电脑：C:\Users\OldUser\Desktop\ABC
新电脑：C:\Users\zhangsan\Desktop\ABC
```

部署脚本会把旧用户目录映射到新用户目录，并同步修改：

- JSONL 中的 `session_meta.cwd`
- JSONL 中的 `turn_context.cwd`
- `workspace_roots`
- SQLite 中的 `threads.cwd`
- SQLite 中的 `threads.rollout_path`
- `.codex-global-state.json` 中的项目路径

随后会创建新路径对应的空项目目录，并尝试注册到 Codex。

## 六、项目为什么只有空文件夹

Codex 历史对话与项目源码是两类数据。

迁移包保存项目路径和对话归属，但不会复制 `.codex` 外部的源码。空项目目录的作用是恢复 Codex 左侧项目分组，使旧对话重新显示在对应项目下。

如果还需要源码，应把旧电脑的项目文件另外复制到脚本创建的对应目录中。例如：

```text
C:\Users\新用户名\Desktop\ABC
```

复制源码前可以保留脚本创建的空文件夹，直接把文件复制进去即可。

## 七、盘符变化

用户目录中的路径能够自动更换用户名，但其他盘符默认保持原路径。

例如：

```text
旧电脑：D:\Projects\ABC
```

如果新电脑也有 `D:`，脚本可以创建或使用相同路径。

如果新电脑没有 `D:`，该项目目录无法自动创建，对话数据仍然存在，但项目分组可能不能自动恢复。此时需要：

1. 在新电脑选择一个实际路径，例如：

```text
C:\Users\新用户名\Documents\Codex-Restored-Projects\ABC
```

2. 创建或复制项目到这个目录。
3. 在 Codex 中手动打开该目录。
4. 如需让旧对话自动归到新路径，还需要对原 `D:\Projects\ABC` 做额外路径映射。

## 八、迁移完成后的检查

启动 Codex 后检查：

- 历史对话是否存在。
- 归档对话是否存在。
- 项目名称和分组是否恢复。
- 点击旧对话能否正常打开。
- Skills 和 Plugins 是否可用。
- 项目路径是否指向新电脑的目录。

部署窗口中应看到类似结果：

```text
部署完成
SQLite 导入/更新线程：若干
数据库完整性：ok
项目路径恢复：可用若干个，新建空目录若干个
```

如果数据库完整性不是 `ok`，不要继续覆盖或删除备份。

## 九、常见问题

### 1. 对话存在，但项目不显示

确认项目路径对应的文件夹已经存在，然后在 Codex 中手动打开一次该目录。Codex 会按照项目绝对路径重新归组历史对话。

### 2. Python 不存在

安装 Python 3，确认以下命令成功，再重新运行部署 BAT：

```powershell
python -c "import sqlite3"
```

### 3. BAT 被 Windows 拦截

确认 BAT 来自本项目。右键文件打开“属性”，如果出现“解除锁定”，勾选后重新运行。公司管理电脑可能需要管理员允许本地 BAT 和 PowerShell。

### 4. 部署中提示 Codex 正在运行

完全退出 Codex，再检查任务管理器。不要在 Codex 或 SQLite 仍在写入时强制部署。

### 5. 需要恢复到部署前状态

先退出 Codex，再使用部署前生成的备份目录恢复：

```text
C:\Users\新用户名\.codex-backup-before-migration-日期时间
```

恢复前建议先把当前失败状态另外保存一份，避免二次覆盖。

## 十、安全提醒

- 迁移 ZIP 包含私人对话、路径、记忆和可能的代码片段，应按私人数据保管。
- 不要把迁移 ZIP 上传到 GitHub、公开帖子或公开分享链接。
- 不要在 Codex 正运行时打包或部署。
- 确认迁移完成并使用一段时间后，再考虑删除旧电脑数据和部署前备份。

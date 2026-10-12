# 开发说明

## 目录

- `CodexM/App/`：SwiftUI 页面、AppKit 菜单和窗口提示。
- `CodexM/Core/`：账户、进程、窗口和接力操作。
- `CodexM/Runtime/`：官方客户端发现、进程身份和辅助功能窗口控制。
- `CodexM/Storage/`：配置存储和文件系统保护。
- `CodexM/Handoff/`：上下文读取、脱敏、Git 状态与接力包。
- `CodexM/Migration/`：原生任务迁移、官方加载器验证、备份与回滚。
- `scripts/`：构建、项目生成、本地化及隔离实验工具。

使用 Xcode 26+；在多版本环境设置 `DEVELOPER_DIR`。项目已包含 scheme 和生成后的工程文件。

```sh
python3 scripts/validate_resources.py
./scripts/build_release.sh
```

发布仓库不包含内部 XCTest、测试计划、人工验收清单或实验测试夹具。原生迁移实验工具仍仅用于本地研究，不是普通用户迁移入口。

添加或删除源码后，可运行 `python3 scripts/generate_project.py` 更新工程。修改翻译后运行资源校验，提交前检查生成文件差异。

## 发布前人工验收

- 首次登录、多个账户同时运行，以及关闭管理器后客户端保持运行。
- 箭头悬停展开、移出关闭、点击固定、菜单行高亮和鼠标跨越菜单间隙。
- 辅助功能允许/拒绝、多个窗口、最小化、全屏与跨桌面聚焦。
- 原生迁移兼容性拒绝、目标仍被占用、重复任务、失败恢复和回滚。
- 升级官方客户端后的重新验证。

原生迁移依赖官方客户端本地协议，不能保证未来版本兼容。不要以放宽进程身份、路径、占用或历史验证来绕过失败。

## 提示与故障定位

用户可在通用设置或错误弹窗中复制诊断信息。报错提供处理建议、操作阶段、稳定错误码和定位编号；记录中的时间使用 ISO 8601。`CM-APP-*` 表示应用状态或校验错误，`CM-NATIVE-<阶段>-<原因>` 表示官方历史协议或 SQLite 错误，`CM-SYSTEM-<域>-<数值>` 保留系统错误分类，`CM-PROCESS-*` 表示客户端异常退出或退出超时，`CM-AX-*` 保留辅助功能操作返回码，`CM-DATA-*` 表示数据解析失败。

最近最多 100 条记录保存在 CodexM 数据目录的 `diagnostics.json`，权限为 0600。后台重复错误按一分钟合并；记录失败不覆盖业务错误。诊断不记录 NSError 原文、userInfo、SQL、账户名称、完整路径、凭据或会话内容。系统统一日志分类为 `dev.codexm.app / Diagnostic`。

SQLite 错误保留主错误码、扩展错误码、系统 errno 和已知数据库文件名。错误 14 表示无法打开数据库或相关文件，不能据此判定格式不兼容。迁移失败明确区分导入前停止与目标数据可能已经变化；导入后的失败报告随迁移记录保存，旧记录仍可读取。接力历史刷新错误不会覆盖最初的操作失败。

接到问题时，先按定位编号匹配记录，再核对操作阶段和底层代码。不要要求用户共享认证文件、完整数据库或私人会话。构建成功不等于 macOS 系统权限或窗口行为已通过实际验收。

原生导入后的 SQLite 完整性检查只覆盖任务历史库 `state_5.sqlite`、`thread_history_1.sqlite` 和 `goals_1.sqlite`。日志、队列、记忆等辅助库有独立生命周期，其故障不用于判定任务历史导入失败；原有历史内容对比、任务路径检查和备份/回滚保护仍然执行。


## 迁移后旧会话无法打开

`failed to resolve rollout path ... file does not exist` 可能是历史索引仍使用旧账户目录的绝对路径。1.0.5 在复制后、提交账户位置前重写目标 `state_*.sqlite` 的 `threads.rollout_path`，核验对应 JSONL 首行会话 ID；不修改原目录，也不更改会话内容、项目归属、目标状态或时间。无法找到的既有历史文件保持原记录。

1.0.6 对已有新增账户在启动前执行同样的路径修复：先通过进程与 Electron 锁检查，在 SQLite 写事务内核验路径和会话 ID，使用 SQLite Backup API 保存含 WAL 数据的快照，再修正路径。备份转为独立数据库并以 0600 权限保存在账户目录的 `history-path-backup-*` 子目录。已正确的路径不会重复产生备份；运行中的账户需要先在 CodexM 停止，然后重新启动。默认账户不执行自动修复。

已有账户也可先用只读工具检查：

```sh
python3 scripts/repair_history_paths.py --home "/实际账户目录/账户UUID/codex"
```

完全退出所有官方客户端（关闭窗口不足以退出），再执行同一命令并添加 `--apply`。工具会拒绝检测到的运行客户端，在账户目录创建权限受限的数据库备份，并仅更新匹配会话 ID 的路径。保留备份以便调查；它包含私人会话元数据，请勿上传。启动客户端后验证原会话可读取、可继续。

验证命令：

```sh
swiftc -swift-version 6 -parse-as-library CodexM/Models/Models.swift CodexM/Storage/ProfileStore.swift tests/ProfileRelocation.swift -o build/profile-relocation-tests -lsqlite3
build/profile-relocation-tests
python3 -m unittest discover -s tests -p 'test_repair_history_paths.py'
```


## 客户端权限归属与系统应用启动

1.0.7 不再通过 `Process` 直接执行客户端主程序，而是通过清理环境后的 `/usr/bin/open -n -a` 请求 Launch Services 启动所选官方 App。`open` 只是短暂的启动桥接；App 的 PID 通过内核启动身份、可执行路径和账户 `--user-data-dir` 参数核验。直接使用 `NSWorkspace.OpenConfiguration.environment` 的测试发现，配置具有叠加性质，会继承来源进程的账户 IPC 等变量，因此不能代替完整环境过滤。

启动后使用已有进程身份轮询检测退出。系统启动的 App 不是可等待的子进程，无法获取原来 `Process.terminationHandler` 的退出状态，界面将其标记为停止，不猜测退出是崩溃还是正常关闭。停止/重启仍只控制通过账户归属核验的正 PID；恢复已运行客户端的方式保持不变。

验证：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/test_desktop_launch.sh
```

原生测试 App 验证两个独立实例、launchd 父进程、账户目录与参数、私有环境变量过滤、账户归属和独立停止。该测试不申请任何隐私权限，不代表官方客户端的具体 TCC 弹窗已经实机验收。更新后需停止旧客户端，再通过新版启动；系统已有权限不会被自动清除或转移。CodexM 自身的窗口控制辅助功能权限仍归 CodexM。需要用户确认官方客户端请求的屏幕录制/控制、麦克风等权限显示正确的 App 名称。

Apple 对 Launch Services 和直接 `NSTask`/`exec` 启动的区别见 [Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/)。


## 原生会话单端往返接力（1.1.0）

迁移前两端账户必须停止，目标与来源的 schema 检查均在数据库私有副本上执行，避免只读 SQLite 查询创建来源 WAL/SHM。来源所选任务仍需满足已有独立任务限制，不迁移凭据或项目文件。会话元数据中项目路径与数据库路径使用规范化路径比较，支持 `/var` 与 `/private/var` 等同一目录的别名。

迁移记录可选字段 `transferKind`、`previousTransferID` 与 `replacedRolloutHash` 保持格式版本 1 的旧记录兼容。最近一个有效 `verified` 记录的目标账户是当前接力账户；`rolledBack` 记录不改变接力归属。已有目标会话只在能够追溯迁移记录时更新，不把偶然相同的会话 ID 当作可覆盖授权。

逐条比较规范化 JSONL 的 SHA-256，要求目标历史是来源历史前缀，同时要求来源仍包含最近一次迁移包的全部历史。仅忽略同一任务的 `thread_settings_applied` 元数据，不忽略用户对话、工具结果或压缩记录。分叉、来源倒退、旧账户继续后再次迁移均在写入前拒绝；完全一致的已完成迁移重试返回原记录而不写入目标。

更新前保留完整目标任务存储快照。替换所选会话的现有 JSONL 路径，仅删除 `thread_history_1.sqlite` 中已知缓存表里该会话的投影。使用官方本地服务重建投影，验证所有轮次与条目的内容哈希，并在重启服务后再次验证。未知的相关投影表或关联数据不会被删除，直接拒绝。导入失败保留备份和失败记录，目标先恢复才能继续；回滚仍要求目标没有发生后续变化，避免覆盖用户新工作。

JSONL 校验与共同历史比较采用流式读取：单文件上限 1 GiB、单行上限 64 MiB；目标快照原有总量/文件数与服务分页限制保持有效。无法读取所有历史时拒绝迁移，不宣称完成。

验证使用无凭据的临时账户和官方客户端嵌入的本地服务，不发起模型请求，也不改动真实账户：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/test_native_round_trip.sh
# 可将所选客户端的内置 codex 可执行文件路径作为第一个参数。
```

覆盖 A → B、B 新增一轮后 B → A、A 再新增后 A → B、官方服务重启后完整历史、重复迁移、旧账户接力拒绝、双端分叉两侧不变、注入导入故障后的备份/回滚，以及超过原 128 MiB 限制的流式历史检查。真实任务的界面显示与继续发送仍需用户验收。

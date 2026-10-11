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

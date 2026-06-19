# 隐私说明

Codex Meter 是一个在本机运行的 macOS 菜单栏应用。

## 应用会访问的数据

- 通过本机 Codex app-server 获取账户套餐、额度百分比和额度重置时间。
- 读取 `~/.codex/sessions/**/*.jsonl` 中的 Codex 活动事件类型、session id、时间戳和必要元数据，用于判断 Agent 是否空闲、工作中、等待授权、阻塞或过期。
- 读取和写入 `~/Library/Application Support/Codex Meter/agent-status.json`，保存本机 Agent 状态灯状态。可通过 `CODEX_METER_AGENT_STATE_FILE` 覆盖路径。
- 在 macOS `UserDefaults` 中保存开机启动偏好、通知去重状态、Codex Desktop 监控开关和状态栏显示模式。

## 网络与数据共享

- 应用自身不包含统计分析、广告或第三方遥测代码。
- 额度数据只来自 Codex app-server 实时服务；应用不会从本地 session 文件计算额度，也会忽略 `token_count` 额度事件。
- 应用不会读取或复制 `~/.codex/auth.json`，也不会收集 API Key、访问令牌或账户密码。
- 应用不会自行把提示词、会话内容或账户凭据上传到开发者或第三方服务。
- Codex app-server 作为 Codex 的一部分，可能按 Codex 自身的工作方式与 OpenAI 服务通信；这不由 Codex Meter 额外实现。

## 系统功能

- 开启额度提醒后，macOS 通知中只包含额度窗口和剩余百分比。
- 开启“开机自动启动”后，应用通过 macOS 登录项机制注册自身。

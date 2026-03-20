# XiaoZhi OpenClaw Headless Bridge

这是一个面向 `小智 MCP` 与 `OpenClaw webhook` 的无界面消息桥接服务。

项目负责建立并维护三段链路：

- 小智 MCP WebSocket 连接
- 本地 `openclaw_tool.py` MCP 工具进程
- OpenClaw `POST /hooks/agent` webhook 调用

它的定位很明确：在本地以稳定、可观测、可配置的方式，把小智侧的工具调用转成 OpenClaw 可直接处理的 agent 消息。

## 快速开始

```bash
# 一键启动（自动检查环境、安装依赖、配置引导、启动服务）
./deploy.sh
```

首次运行会进入配置引导，按提示输入：
- MCP Endpoint：小智 MCP 连接地址
- OpenClaw URL：默认 `http://127.0.0.1:18789`
- Hook Token：OpenClaw 的 webhook token

## 系统服务

支持 macOS (launchd) 和 Linux (systemd) 双平台。

> **注意**：`./deploy.sh` 或 `./deploy.sh serve` 是前台运行模式，适合调试。若要后台运行并开机自启，请使用下面的服务命令。

```bash
./deploy.sh install     # 安装为系统服务（开机自启）
./deploy.sh start       # 启动服务
./deploy.sh stop        # 停止服务
./deploy.sh restart     # 重启服务
./deploy.sh status      # 查看服务状态
./deploy.sh logs        # 实时查看日志
./deploy.sh uninstall   # 移除系统服务
```

## 部署脚本命令

| 命令 | 说明 |
|------|------|
| `./deploy.sh` 或 `serve` | 检查环境 → 创建 venv → 安装依赖 → 检查配置 → 前台启动服务 |
| `./deploy.sh init` | 进入配置引导模式 |
| `./deploy.sh install` | 安装为系统服务 |
| `./deploy.sh uninstall` | 移除系统服务 |
| `./deploy.sh start/stop/restart` | 服务管理 |
| `./deploy.sh status` | 查看服务状态 |
| `./deploy.sh logs` | tail -f 日志文件 |

## 文件说明

- `deploy.sh`：一键部署脚本，支持 macOS/Linux 双平台
- `main.py`：统一命令行入口，提供初始化、校验、自检、直发消息和服务启动命令
- `mcp_pipe.py`：负责小智 MCP WebSocket 与本地 stdio 工具进程之间的通信
- `openclaw_tool.py`：对外暴露 MCP 工具，并把消息投递到 OpenClaw webhook
- `config.py`：本地配置加载、归一化、保存与校验
- `bridge_logging.py`：结构化日志输出与关键信息提取
- `config.example.json`：配置示例

## 配置 OpenClaw

在 `~/.openclaw/openclaw.json` 中启用 hooks：

```json
{
  "hooks": {
    "enabled": true,
    "token": "your-hook-token",
    "allowRequestSessionKey": true,
    "path": "/hooks"
  }
}
```

配置生效后重启网关：

```bash
openclaw gateway restart
```

## 手动安装（可选）

如需手动管理：

```bash
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
```

## 手动配置（可选）

```bash
./.venv/bin/python main.py init \
  --mcp-endpoint 'wss://api.xiaozhi.me/mcp/?token=你的token' \
  --openclaw-url 'http://127.0.0.1:18789' \
  --hook-token 'your-hook-token'
```

默认在当前目录写入 `config.json`，可通过环境变量 `XIAOZHI_OPENCLAW_CONFIG` 指定路径。

## 常用命令

```bash
# 检查配置
./.venv/bin/python main.py validate

# 检查 OpenClaw 服务状态
./.venv/bin/python main.py health

# 直接发送消息
./.venv/bin/python main.py send "你好，给我总结一下当前系统状态"

# 前台启动服务
./.venv/bin/python main.py serve
```

## 运行行为

服务启动后会持续完成以下工作：

- 连接小智 MCP WebSocket
- 启动本地 `openclaw_tool.py` 工具进程
- 将工具调用转换为 OpenClaw `POST /hooks/agent` 请求
- 把请求结果返回给小智侧

项目将 OpenClaw `200` 与 `202` 响应都视为成功接受。

## 配置说明

默认配置项：

```json
{
  "MCP_ENDPOINT": "wss://api.xiaozhi.me/mcp/?token=replace-me",
  "OPENCLAW_URL": "http://127.0.0.1:18789",
  "HOOK_TOKEN": "replace-me",
  "HOOK_NAME": "XiaoZhi",
  "AGENT_ID": "",
  "SESSION_KEY": "",
  "WAKE_MODE": "now",
  "DELIVER": true,
  "CHANNEL": "last",
  "TO": "",
  "MODEL": "",
  "THINKING": "",
  "TIMEOUT_SECONDS": 120,
  "LOG_ENABLED": false,
  "LOG_PATH": "logs/bridge_events.jsonl"
}
```

说明：

- `AGENT_ID`、`CHANNEL`、`TO`、`MODEL`、`THINKING` 可作为默认投递参数保存到配置中
- `send` 命令支持对这些参数做单次覆盖
- `SESSION_KEY` 留空时由运行时会话自然分配；固定后会把多次消息归入同一会话
- `WAKE_MODE` 只支持 `now` 或 `next-heartbeat`
- `USE_SOCKS_PROXY` 是否安装 SOCKS 代理支持 (python-socks)，默认 `true`

## 日志排查

开启日志：

```json
{
  "LOG_ENABLED": true
}
```

查看日志：

```bash
./deploy.sh logs
# 或
tail -f logs/bridge_events.jsonl
```

日志事件：

- `xiaozhi_to_tool`：小智 WSS 下发到本地 MCP 工具的原始消息
- `tool_to_xiaozhi`：本地 MCP 工具返回给小智 WSS 的原始消息
- `openclaw_webhook_request`：发送给 OpenClaw 的 webhook 请求体
- `openclaw_webhook_response`：OpenClaw 返回结果
- `openclaw_health_check`：本地健康检查请求结果

每条日志包含 `interesting` 字段，提取 `id`、`session*`、`conversation*`、`request*`、`trace*`、`call*`、`agent*` 等关键信息，方便对照小智侧与 OpenClaw 侧链路。

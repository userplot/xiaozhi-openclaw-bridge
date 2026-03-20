#!/bin/bash
#
# xiaozhi-openclaw-bridge 一键部署脚本
# 支持 macOS (launchd) 和 Linux (systemd)
#

set -e

# ============================================================================
# 全局变量
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="xiaozhi-openclaw-bridge"
VENV_DIR="$SCRIPT_DIR/.venv"
CONFIG_FILE="$SCRIPT_DIR/config.json"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/bridge_events.jsonl"
PYTHON_MIN_VERSION="3.10"

# macOS launchd
PLIST_NAME="com.xiaozhi.openclaw-bridge"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

# Linux systemd
SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="xiaozhi-openclaw-bridge"
SERVICE_PATH="$SYSTEMD_DIR/$SERVICE_NAME.service"

# ============================================================================
# 颜色定义
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ============================================================================
# 系统检测
# ============================================================================

detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*)  echo "linux" ;;
        *)       error "不支持的操作系统: $(uname -s)" ;;
    esac
}

OS=$(detect_os)

# ============================================================================
# Python 版本检测
# ============================================================================

check_python() {
    local python_cmd=""
    local version=""

    # 优先尝试 python3
    if command -v python3 &> /dev/null; then
        python_cmd="python3"
    elif command -v python &> /dev/null; then
        python_cmd="python"
    else
        error "未找到 Python，请先安装 Python $PYTHON_MIN_VERSION 或更高版本"
    fi

    # 检查版本
    version=$($python_cmd -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

    # 版本比较
    local required=$PYTHON_MIN_VERSION
    if [ "$(printf '%s\n' "$required" "$version" | sort -V | head -n1)" != "$required" ]; then
        error "Python 版本过低: $version，需要 $PYTHON_MIN_VERSION 或更高版本"
    fi

    echo "$python_cmd"
}

# ============================================================================
# 虚拟环境管理
# ============================================================================

ensure_venv() {
    local python_cmd=$(check_python)

    if [ ! -d "$VENV_DIR" ]; then
        info "创建虚拟环境..."
        $python_cmd -m venv "$VENV_DIR"
        success "虚拟环境创建成功: $VENV_DIR"
    fi
}

install_deps() {
    ensure_venv

    info "安装/更新依赖..."
    "$VENV_DIR/bin/pip" install --upgrade pip -q
    "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt" -q

    # 检查是否需要安装 SOCKS 代理支持
    if [ -f "$CONFIG_FILE" ]; then
        local use_socks=$(grep -o '"USE_SOCKS_PROXY"[[:space:]]*:[[:space:]]*[^,}]*' "$CONFIG_FILE" | grep -o 'true\|false' || echo "true")
        if [ "$use_socks" = "true" ]; then
            info "安装 SOCKS 代理支持..."
            "$VENV_DIR/bin/pip" install python-socks -q
        fi
    else
        # 没有配置文件时默认安装
        "$VENV_DIR/bin/pip" install python-socks -q
    fi

    success "依赖安装完成"
}

# ============================================================================
# 配置引导
# ============================================================================

check_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        warn "配置文件不存在: $CONFIG_FILE"
        echo ""
        do_init
    fi
}

do_init() {
    info "进入配置引导模式..."
    echo ""

    # MCP Endpoint
    echo -e "${YELLOW}请输入 MCP Endpoint (小智 MCP 连接地址)${NC}"
    read -p "例如 wss://api.xiaozhi.me/mcp/?token=xxx: " mcp_endpoint
    if [ -z "$mcp_endpoint" ]; then
        error "MCP Endpoint 不能为空"
    fi

    # OpenClaw URL
    echo ""
    echo -e "${YELLOW}请输入 OpenClaw URL${NC}"
    read -p "默认 [http://127.0.0.1:18789]: " openclaw_url
    openclaw_url=${openclaw_url:-http://127.0.0.1:18789}

    # Hook Token
    echo ""
    echo -e "${YELLOW}请输入 Hook Token (OpenClaw 的 webhook token)${NC}"
    read -p "Hook Token: " hook_token
    if [ -z "$hook_token" ]; then
        error "Hook Token 不能为空"
    fi

    # 可选配置
    echo ""
    echo -e "${YELLOW}可选配置 (直接回车跳过)${NC}"
    read -p "Agent ID: " agent_id
    read -p "Channel: " channel
    read -p "To: " to

    # SOCKS 代理支持
    echo ""
    read -p "是否安装 SOCKS 代理支持 (python-socks)? [Y/n]: " install_socks
    install_socks=${install_socks:-Y}
    if [[ "$install_socks" =~ ^[Yy]$ ]] || [[ -z "$install_socks" ]]; then
        use_socks_proxy="true"
    else
        use_socks_proxy="false"
    fi

    # 构建命令
    local cmd="$VENV_DIR/bin/python $SCRIPT_DIR/main.py init"
    cmd="$cmd --mcp-endpoint \"$mcp_endpoint\""
    cmd="$cmd --openclaw-url \"$openclaw_url\""
    cmd="$cmd --hook-token \"$hook_token\""

    [ -n "$agent_id" ] && cmd="$cmd --agent-id \"$agent_id\""
    [ -n "$channel" ] && cmd="$cmd --channel \"$channel\""
    [ -n "$to" ] && cmd="$cmd --to \"$to\""
    cmd="$cmd --use-socks-proxy \"$use_socks_proxy\""

    echo ""
    info "正在生成配置文件..."
    eval "$cmd"
    success "配置文件生成完成"
}

# ============================================================================
# serve 命令 (默认)
# ============================================================================

do_serve() {
    install_deps
    check_config

    info "启动服务..."
    exec "$VENV_DIR/bin/python" "$SCRIPT_DIR/main.py" serve
}

# ============================================================================
# macOS launchd 服务管理
# ============================================================================

macos_install() {
    if [ -f "$PLIST_PATH" ]; then
        warn "服务已安装，先卸载旧服务..."
        macos_uninstall
    fi

    # 确保依赖和配置
    install_deps
    check_config

    # 创建日志目录
    mkdir -p "$LOG_DIR"

    # 生成 plist
    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$VENV_DIR/bin/python</string>
        <string>$SCRIPT_DIR/main.py</string>
        <string>serve</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF

    # 加载服务
    launchctl bootstrap gui/$(id -u) "$PLIST_PATH" 2>/dev/null || \
        launchctl load "$PLIST_PATH"

    success "服务安装成功"
    info "使用 'deploy.sh status' 查看服务状态"
}

macos_uninstall() {
    # 停止并卸载
    launchctl bootout gui/$(id -u)/"$PLIST_NAME" 2>/dev/null || \
        launchctl unload "$PLIST_PATH" 2>/dev/null || true

    # 删除 plist
    rm -f "$PLIST_PATH"

    success "服务已卸载"
}

macos_start() {
    # 如果服务未加载，先加载
    launchctl print gui/$(id -u)/"$PLIST_NAME" &>/dev/null || \
        launchctl bootstrap gui/$(id -u) "$PLIST_PATH" 2>/dev/null || \
        launchctl load "$PLIST_PATH" 2>/dev/null
    success "服务已启动"
}

macos_stop() {
    # 需要 unload 才能真正停止 (因为 KeepAlive 会自动重启)
    launchctl bootout gui/$(id -u)/"$PLIST_NAME" 2>/dev/null || \
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
    success "服务已停止"
}

macos_restart() {
    macos_stop
    sleep 1
    macos_start
}

macos_status() {
    if [ ! -f "$PLIST_PATH" ]; then
        echo "服务未安装"
        return
    fi

    # 检查服务是否已加载
    local loaded=$(launchctl print gui/$(id -u)/"$PLIST_NAME" 2>/dev/null)

    if [ -z "$loaded" ]; then
        echo "服务已安装但未运行"
        echo ""
        echo "使用以下命令启动: ./deploy.sh start"
    else
        echo "服务状态: 运行中"
        # 提取关键信息
        local pid=$(echo "$loaded" | grep -E "^\s*pid\s*=" | awk '{print $3}')
        local status=$(echo "$loaded" | grep -E "^\s*status\s*=" | awk '{print $3}')

        [ -n "$pid" ] && echo "PID: $pid"
        [ -n "$status" ] && echo "状态码: $status"
        echo ""
        echo "日志目录: $LOG_DIR"
        echo "使用以下命令查看日志: ./deploy.sh logs"
    fi
}

# ============================================================================
# Linux systemd 服务管理
# ============================================================================

linux_install() {
    if [ -f "$SERVICE_PATH" ]; then
        warn "服务已安装，先卸载旧服务..."
        linux_uninstall
    fi

    # 确保依赖和配置
    install_deps
    check_config

    # 创建目录
    mkdir -p "$SYSTEMD_DIR"
    mkdir -p "$LOG_DIR"

    # 生成 service 文件
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=XiaoZhi OpenClaw MCP Bridge
After=network.target

[Service]
Type=simple
ExecStart=$VENV_DIR/bin/python $SCRIPT_DIR/main.py serve
WorkingDirectory=$SCRIPT_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

    # 重载 systemd
    systemctl --user daemon-reload

    # 启用服务
    systemctl --user enable "$SERVICE_NAME"

    # 检查是否需要 enable-linger
    if [ ! -f "/var/lib/systemd/linger/$(whoami)" ]; then
        warn "为确保开机自启，正在启用用户 linger..."
        loginctl enable-linger "$(whoami)" 2>/dev/null || \
            warn "无法启用 linger，可能需要管理员权限运行: loginctl enable-linger $(whoami)"
    fi

    success "服务安装成功"
    info "使用 'deploy.sh start' 启动服务"
    info "使用 'deploy.sh status' 查看服务状态"
}

linux_uninstall() {
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_PATH"
    systemctl --user daemon-reload
    success "服务已卸载"
}

linux_start() {
    systemctl --user start "$SERVICE_NAME"
    success "服务已启动"
}

linux_stop() {
    systemctl --user stop "$SERVICE_NAME"
    success "服务已停止"
}

linux_restart() {
    systemctl --user restart "$SERVICE_NAME"
    success "服务已重启"
}

linux_status() {
    systemctl --user status "$SERVICE_NAME" --no-pager || true
}

# ============================================================================
# 日志查看
# ============================================================================

do_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        # 尝试其他日志文件
        if [ -f "$LOG_DIR/stdout.log" ]; then
            tail -f "$LOG_DIR/stdout.log" "$LOG_DIR/stderr.log" 2>/dev/null
        else
            warn "日志文件不存在: $LOG_FILE"
            info "服务可能尚未运行或日志未启用"
            exit 1
        fi
    else
        tail -f "$LOG_FILE"
    fi
}

# ============================================================================
# 帮助信息
# ============================================================================

show_help() {
    cat << EOF
xiaozhi-openclaw-bridge 一键部署脚本

用法:
    ./deploy.sh [command]

命令:
    serve       检查环境 → 创建 venv → 安装依赖 → 检查配置 → 前台启动服务 (默认)
    init        进入配置引导模式
    install     安装为系统服务
    uninstall   移除系统服务
    start       启动服务
    stop        停止服务
    restart     重启服务
    status      查看服务状态
    logs        tail -f 日志文件
    help        显示此帮助信息

平台:
    当前系统: $OS
    服务类型: $([ "$OS" = "macos" ] && echo "launchd" || echo "systemd")

EOF
}

# ============================================================================
# 主入口
# ============================================================================

main() {
    local command=${1:-serve}

    case "$command" in
        serve)
            do_serve
            ;;
        init)
            ensure_venv
            install_deps
            do_init
            ;;
        install)
            if [ "$OS" = "macos" ]; then
                macos_install
            else
                linux_install
            fi
            ;;
        uninstall)
            if [ "$OS" = "macos" ]; then
                macos_uninstall
            else
                linux_uninstall
            fi
            ;;
        start)
            if [ "$OS" = "macos" ]; then
                macos_start
            else
                linux_start
            fi
            ;;
        stop)
            if [ "$OS" = "macos" ]; then
                macos_stop
            else
                linux_stop
            fi
            ;;
        restart)
            if [ "$OS" = "macos" ]; then
                macos_restart
            else
                linux_restart
            fi
            ;;
        status)
            if [ "$OS" = "macos" ]; then
                macos_status
            else
                linux_status
            fi
            ;;
        logs)
            do_logs
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "未知命令: $command\n运行 './deploy.sh help' 查看可用命令"
            ;;
    esac
}

main "$@"

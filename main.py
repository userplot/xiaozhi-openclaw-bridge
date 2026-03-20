import argparse
import json
from pathlib import Path

from config import (
    load_config,
    save_config,
    validate_config,
)


def cmd_init(args) -> int:
    config = load_config()
    updates = {
        "MCP_ENDPOINT": args.mcp_endpoint,
        "OPENCLAW_URL": args.openclaw_url,
        "HOOK_TOKEN": args.hook_token,
        "HOOK_NAME": args.hook_name,
        "AGENT_ID": args.agent_id,
        "CHANNEL": args.channel,
        "TO": args.to,
        "MODEL": args.model,
        "THINKING": args.thinking,
        "WAKE_MODE": args.wake_mode,
        "TIMEOUT_SECONDS": args.timeout_seconds,
    }
    for key, value in updates.items():
        if value is not None:
            config[key] = value
    if args.deliver is not None:
        config["DELIVER"] = args.deliver
    if args.use_socks_proxy is not None:
        config["USE_SOCKS_PROXY"] = args.use_socks_proxy

    config_path = save_config(config)
    print(f"配置已写入: {config_path}")
    return 0


def cmd_show_config(args) -> int:
    config = load_config()
    print(json.dumps(config, ensure_ascii=False, indent=2))
    return 0


def cmd_validate(args) -> int:
    config = load_config()
    errors = validate_config(config)
    if not errors:
        print("配置有效")
        return 0
    for error in errors:
        print(error)
    return 1


def cmd_health(args) -> int:
    from openclaw_tool import check_health

    result = check_health()
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["success"] else 1


def cmd_send(args) -> int:
    from openclaw_tool import send_agent_message

    result = send_agent_message(
        args.message,
        name=args.name,
        deliver=args.deliver,
        wake_mode=args.wake_mode,
        agent_id=args.agent_id,
        channel=args.channel,
        to=args.to,
        model=args.model,
        thinking=args.thinking,
        timeout_seconds=args.timeout_seconds,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["success"] else 1


def cmd_serve(args) -> int:
    from mcp_pipe import main as pipe_main

    return pipe_main([str(Path(__file__).resolve().parent / "openclaw_tool.py")])


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="无界面的 XiaoZhi <-> OpenClaw MCP 桥接器"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init", help="写入或更新本地配置")
    init_parser.add_argument("--mcp-endpoint")
    init_parser.add_argument("--openclaw-url")
    init_parser.add_argument("--hook-token")
    init_parser.add_argument("--hook-name")
    init_parser.add_argument("--agent-id")
    init_parser.add_argument("--channel")
    init_parser.add_argument("--to")
    init_parser.add_argument("--model")
    init_parser.add_argument("--thinking")
    init_parser.add_argument("--wake-mode", choices=["now", "next-heartbeat"])
    init_parser.add_argument("--timeout-seconds", type=int)
    init_parser.add_argument(
        "--deliver",
        dest="deliver",
        action="store_true",
        default=None,
    )
    init_parser.add_argument(
        "--no-deliver",
        dest="deliver",
        action="store_false",
    )
    init_parser.add_argument(
        "--use-socks-proxy",
        dest="use_socks_proxy",
        type=lambda x: x.lower() in ("true", "1", "yes"),
        default=None,
    )
    init_parser.set_defaults(func=cmd_init)

    show_parser = subparsers.add_parser("show-config", help="打印当前配置")
    show_parser.set_defaults(func=cmd_show_config)

    validate_parser = subparsers.add_parser("validate", help="校验当前配置")
    validate_parser.set_defaults(func=cmd_validate)

    health_parser = subparsers.add_parser("health", help="检测 OpenClaw 健康状态")
    health_parser.set_defaults(func=cmd_health)

    send_parser = subparsers.add_parser("send", help="直接发送一条 webhook 消息")
    send_parser.add_argument("message")
    send_parser.add_argument("--name")
    send_parser.add_argument("--agent-id")
    send_parser.add_argument("--wake-mode", choices=["now", "next-heartbeat"])
    send_parser.add_argument("--channel")
    send_parser.add_argument("--to")
    send_parser.add_argument("--model")
    send_parser.add_argument("--thinking")
    send_parser.add_argument("--timeout-seconds", type=int)
    send_parser.add_argument(
        "--deliver",
        dest="deliver",
        action="store_true",
        default=None,
    )
    send_parser.add_argument(
        "--no-deliver",
        dest="deliver",
        action="store_false",
    )
    send_parser.set_defaults(func=cmd_send)

    serve_parser = subparsers.add_parser("serve", help="启动无界面的 MCP 桥接服务")
    serve_parser.set_defaults(func=cmd_serve)

    return parser

def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

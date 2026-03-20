import logging
from typing import Any

import requests

from bridge_logging import extract_interesting_fields, log_event
from config import load_config

try:
    from fastmcp import FastMCP
except ImportError:  # pragma: no cover
    from mcp.server.fastmcp import FastMCP


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("openclaw_tool")

mcp = FastMCP("OpenClawBridge")


def _compact_payload(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in payload.items()
        if value not in (None, "", [])
    }


def _request_headers(token: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }


def build_agent_payload(
    message: str,
    *,
    name: str | None = None,
    deliver: bool | None = None,
    wake_mode: str | None = None,
    agent_id: str | None = None,
    channel: str | None = None,
    to: str | None = None,
    model: str | None = None,
    thinking: str | None = None,
    timeout_seconds: int | None = None,
) -> dict[str, Any]:
    config = load_config()
    payload = {
        "message": message,
        "name": name or config.get("HOOK_NAME"),
        "deliver": config.get("DELIVER") if deliver is None else deliver,
        "wakeMode": wake_mode or config.get("WAKE_MODE"),
        "agentId": agent_id or config.get("AGENT_ID"),
        "channel": channel or config.get("CHANNEL"),
        "sessionKey": config.get("SESSION_KEY"),
        "to": to or config.get("TO"),
        "model": model or config.get("MODEL"),
        "thinking": thinking or config.get("THINKING"),
        "timeoutSeconds": timeout_seconds or config.get("TIMEOUT_SECONDS"),
    }
    return _compact_payload(payload)


def send_agent_message(message: str, **kwargs) -> dict[str, Any]:
    config = load_config()
    payload = build_agent_payload(message, **kwargs)
    url = config["OPENCLAW_URL"].rstrip("/") + "/hooks/agent"
    log_event(
        "openclaw_webhook_request",
        url=url,
        payload=payload,
        interesting=extract_interesting_fields(payload),
    )
    response = requests.post(
        url,
        headers=_request_headers(config["HOOK_TOKEN"]),
        json=payload,
        timeout=max(int(config.get("TIMEOUT_SECONDS", 120)), 5) + 5,
    )

    body: Any
    try:
        body = response.json()
    except ValueError:
        body = response.text.strip()

    accepted = response.status_code in {200, 202}
    result = {
        "success": accepted,
        "status_code": response.status_code,
        "payload": payload,
        "response": body,
    }
    log_event(
        "openclaw_webhook_response",
        url=url,
        status_code=response.status_code,
        response=body,
        interesting=extract_interesting_fields(body) if isinstance(body, (dict, list)) else [],
    )
    if accepted:
        logger.info("OpenClaw accepted webhook request")
    else:
        logger.error("OpenClaw webhook request failed with status %s", response.status_code)
    return result


def check_health() -> dict[str, Any]:
    config = load_config()
    url = config["OPENCLAW_URL"].rstrip("/") + "/health"
    response = requests.get(url, timeout=5)
    body: Any
    try:
        body = response.json()
    except ValueError:
        body = response.text.strip()
    result = {
        "success": response.ok,
        "status_code": response.status_code,
        "response": body,
    }
    log_event(
        "openclaw_health_check",
        url=url,
        status_code=response.status_code,
        response=body,
    )
    return result


@mcp.tool(name="send_message")
def send_message_tool(
    message: str,
    name: str = "",
    deliver: bool | None = None,
    wake_mode: str = "",
    agent_id: str = "",
    channel: str = "",
    to: str = "",
    model: str = "",
    thinking: str = "",
    timeout_seconds: int | None = None,
) -> dict[str, Any]:
    """
    向 OpenClaw（小龙虾）发送消息，由 AI Agent 进行处理。
    用途：当你需要调用外部 AI 能力、处理复杂任务、或与 OpenClaw（小龙虾）生态交互时使用此工具。
    """
    return send_agent_message(
        message,
        name=name or None,
        deliver=deliver,
        wake_mode=wake_mode or None,
        agent_id=agent_id or None,
        channel=channel or None,
        to=to or None,
        model=model or None,
        thinking=thinking or None,
        timeout_seconds=timeout_seconds,
    )


# @mcp.tool(name="check_openclaw_health")
# def check_openclaw_health_tool() -> dict[str, Any]:
#     """检查 OpenClaw（小龙虾）服务是否可访问。"""
#     return check_health()


if __name__ == "__main__":
    mcp.run(transport="stdio")

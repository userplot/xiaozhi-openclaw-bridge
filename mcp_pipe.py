import asyncio
import json
import logging
import signal
import subprocess
import sys
from collections.abc import Sequence

import websockets
from dotenv import load_dotenv

from bridge_logging import log_event, log_json_message
from config import load_config as _load_config


load_dotenv()
_config = _load_config()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("mcp_pipe")

INITIAL_BACKOFF_SECONDS = 1
MAX_BACKOFF_SECONDS = 300


async def pipe_websocket_to_process(websocket, process: subprocess.Popen) -> None:
    try:
        while True:
            message = await websocket.recv()
            if isinstance(message, bytes):
                message = message.decode("utf-8")
            log_json_message("xiaozhi_to_tool", message)
            process.stdin.write(message + "\n")
            process.stdin.flush()
    finally:
        if process.stdin and not process.stdin.closed:
            process.stdin.close()


async def pipe_process_to_websocket(process: subprocess.Popen, websocket) -> None:
    try:
        while True:
            data = await asyncio.to_thread(process.stdout.readline)
            if not data:
                logger.info("server stdout closed")
                return
            log_json_message("tool_to_xiaozhi", data.rstrip("\n"))
            await websocket.send(data)

            # 发送响应后断开连接（防止消息轰炸）
            if _config.get("DISCONNECT_AFTER_RESPONSE"):
                logger.info("disconnecting after response (DISCONNECT_AFTER_RESPONSE=true)")
                log_event("disconnect_after_response")
                await websocket.close()
                return
    except websockets.ConnectionClosed:
        pass


async def pipe_process_stderr(process: subprocess.Popen) -> None:
    while True:
        data = await asyncio.to_thread(process.stderr.readline)
        if not data:
            logger.info("server stderr closed")
            return
        log_event("tool_stderr", line=data.rstrip("\n"))
        sys.stderr.write(data)
        sys.stderr.flush()


async def run_once(endpoint_url: str, command: Sequence[str]) -> None:
    process = None
    try:
        logger.info("connecting to MCP endpoint")
        log_event("bridge_connecting", endpoint="configured")
        async with websockets.connect(endpoint_url) as websocket:
            logger.info("connected to MCP endpoint")
            process = subprocess.Popen(
                list(command),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                encoding="utf-8",
                text=True,
            )
            logger.info("started tool process: %s", " ".join(command))
            log_event(
                "bridge_connected",
                tool_command=list(command),
                tool_pid=process.pid,
            )
            await asyncio.gather(
                pipe_websocket_to_process(websocket, process),
                pipe_process_to_websocket(process, websocket),
                pipe_process_stderr(process),
            )
    finally:
        if process is not None:
            logger.info("stopping tool process")
            log_event("tool_process_stopping", tool_pid=process.pid)
            process.terminate()
            try:
                await asyncio.to_thread(process.wait, 5)
            except subprocess.TimeoutExpired:
                process.kill()


async def run_forever(endpoint_url: str, command: Sequence[str]) -> None:
    attempt = 0
    backoff = INITIAL_BACKOFF_SECONDS
    while True:
        try:
            if attempt > 0:
                logger.info("retrying in %s seconds", backoff)
                await asyncio.sleep(backoff)
            await run_once(endpoint_url, command)
            attempt = 0
            backoff = INITIAL_BACKOFF_SECONDS
        except Exception as exc:  # pragma: no cover
            attempt += 1
            logger.warning("bridge disconnected (attempt %s): %s", attempt, exc)
            log_event("bridge_disconnected", attempt=attempt, error=str(exc))
            backoff = min(backoff * 2, MAX_BACKOFF_SECONDS)


def install_signal_handlers() -> None:
    def _handle_signal(signum, frame):
        logger.info("received signal %s, exiting", signum)
        raise SystemExit(0)

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)


def main(argv: Sequence[str] | None = None) -> int:
    from config import load_config, validate_config

    install_signal_handlers()
    args = list(argv or sys.argv[1:])
    tool_script = args[0] if args else "openclaw_tool.py"
    config = load_config()
    errors = validate_config(config)
    if errors:
        for error in errors:
            logger.error(error)
        return 1

    command = [sys.executable, tool_script]
    asyncio.run(run_forever(config["MCP_ENDPOINT"], command))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

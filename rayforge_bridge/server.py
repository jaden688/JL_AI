"""
Rayforge control bridge — a small local HTTP server that drives Rayforge's
headless DocEditor/MachineCmd API in-process, so JL Engine (and any other
MCP/HTTP client) can puppet the real Rayforge install: import a design,
configure cut/engrave steps, generate G-code, and drive the physical machine.

Requires `rayforge` to be importable in whatever Python runs this file
(installed into a real interpreter, e.g. via `pip install -e <rayforge repo>`
— NOT a venv, per project convention: BYTE.jl shells out to ENV["PYTHON"] /
plain "python" on PATH, so the same interpreter must have rayforge + its
deps installed globally).

By default this uses Rayforge's own config directory (same one the desktop
app uses — respects RAYFORGE_CONFIG_DIR, defaults to
platformdirs.user_config_dir("rayforge")), so it drives your actual
configured machine(s). Do not run this at the same time as the Rayforge
GUI app against the same config dir — both write config.yaml on shutdown.

Safety:
  - Never auto-connects to a machine on boot. A machine must be connected
    explicitly via POST /machine/connect before any motion/power/job
    endpoint will act.
  - Laser power is hard-clamped to RAYFORGE_BRIDGE_MAX_POWER_PCT (default
    60), matching the existing hard limit used by the Ruida MCP tools
    elsewhere in this repo.

Run:
    python -m rayforge_bridge.server
Env:
    RAYFORGE_BRIDGE_HOST          default 127.0.0.1
    RAYFORGE_BRIDGE_PORT          default 8091
    RAYFORGE_BRIDGE_MAX_POWER_PCT default 60
    RAYFORGE_CONFIG_DIR           passed straight through to rayforge (optional)
"""

import asyncio
import json
import logging
import os
from pathlib import Path
from typing import Any, Dict, Optional

from aiohttp import web

logger = logging.getLogger("rayforge_bridge")
logging.basicConfig(level=logging.INFO)

HOST = os.environ.get("RAYFORGE_BRIDGE_HOST", "127.0.0.1")
PORT = int(os.environ.get("RAYFORGE_BRIDGE_PORT", "8091"))
MAX_POWER_PCT = float(os.environ.get("RAYFORGE_BRIDGE_MAX_POWER_PCT", "60"))


class BridgeState:
    """Lazily-initialized, process-wide handle on the headless Rayforge stack."""

    def __init__(self):
        self.context = None
        self.task_manager = None
        self.editor = None
        self.machine_cmd = None
        self._init_lock = asyncio.Lock()

    async def ensure_ready(self):
        if self.editor is not None:
            return
        async with self._init_lock:
            if self.editor is not None:
                return
            self._init_sync()

    def _init_sync(self):
        from rayforge.shared.tasker.manager import TaskManager
        from rayforge.context import get_context
        from rayforge.doceditor.editor import DocEditor
        from rayforge.machine.cmd import MachineCmd

        loop = asyncio.get_event_loop()

        def scheduler(callback, *args, **kwargs):
            if not loop.is_closed():
                loop.call_soon_threadsafe(lambda: callback(*args, **kwargs))

        self.task_manager = TaskManager(main_thread_scheduler=scheduler)
        context = get_context()
        context._headless = True
        shared_state = self.task_manager.get_shared_state()
        context.addon_mgr.set_task_manager(self.task_manager)
        context.addon_mgr.set_shared_state(shared_state)
        self.context = context

        self.editor = DocEditor(self.task_manager, context)
        self.machine_cmd = MachineCmd(self.editor)
        logger.info("Rayforge headless stack initialized (config dir: %s)", _config_dir())

    @property
    def machine(self):
        if self.context is None:
            return None
        return self.context.config.machine


def _config_dir() -> str:
    try:
        from rayforge import config as rf_config
        return str(rf_config.CONFIG_DIR)
    except Exception:
        return os.environ.get("RAYFORGE_CONFIG_DIR", "<default>")


STATE = BridgeState()


def _json_error(message: str, status: int = 400) -> web.Response:
    return web.json_response({"error": message}, status=status)


def _doc_summary(doc) -> Dict[str, Any]:
    layers = []
    for layer in doc.layers:
        steps = []
        if layer.workflow:
            steps = [
                {"type": s.typelabel, "uid": getattr(s, "uid", None)}
                for s in layer.workflow.steps
            ]
        layers.append(
            {
                "name": layer.name,
                "workpieces": len(layer.workpieces),
                "has_fills": layer.has_fills,
                "steps": steps,
            }
        )
    return {"layers": layers}


def _machine_summary(machine) -> Optional[Dict[str, Any]]:
    if machine is None:
        return None
    return {
        "name": machine.name,
        "driver": machine.driver_name,
        "driver_args": {
            k: v for k, v in machine.driver_args.items() if k != "password"
        },
        "connected": machine.is_connected(),
        "home_on_start": machine.home_on_start,
    }


# ── Routes ───────────────────────────────────────────────────────────────


async def handle_status(request: web.Request) -> web.Response:
    await STATE.ensure_ready()
    editor = STATE.editor
    return web.json_response(
        {
            "config_dir": _config_dir(),
            "headless": STATE.context._headless,
            "is_processing": editor.is_processing,
            "doc": _doc_summary(editor.doc),
            "machine": _machine_summary(STATE.machine),
            "max_power_pct": MAX_POWER_PCT,
        }
    )


async def handle_import(request: web.Request) -> web.Response:
    await STATE.ensure_ready()
    body = await request.json()
    path = body.get("path")
    if not path:
        return _json_error("'path' is required")
    file_path = Path(path)
    if not file_path.exists():
        return _json_error(f"file not found: {file_path}", status=404)

    mime_type = body.get("mime_type")
    before = len(STATE.editor.doc.layers)
    await STATE.editor.import_file_from_path(file_path, mime_type, None)
    await STATE.editor.wait_until_settled(timeout=body.get("timeout", 30))
    after_layers = STATE.editor.doc.layers
    new_layers = after_layers[before:]
    return web.json_response(
        {
            "imported": str(file_path),
            "new_layers": len(new_layers),
            "doc": _doc_summary(STATE.editor.doc),
        }
    )


async def handle_add_default_steps(request: web.Request) -> web.Response:
    await STATE.ensure_ready()
    editor = STATE.editor
    editor.step.add_default_steps_for_layers(editor.doc.layers)
    await editor.wait_until_settled(timeout=30)
    return web.json_response({"doc": _doc_summary(editor.doc)})


async def handle_export_gcode(request: web.Request) -> web.Response:
    await STATE.ensure_ready()
    body = await request.json()
    output_path = body.get("output_path")
    if not output_path:
        return _json_error("'output_path' is required")
    out = Path(output_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    await STATE.editor.export_gcode_to_path(out)
    gcode = out.read_text(encoding="utf-8")
    return web.json_response(
        {
            "output_path": str(out),
            "bytes": len(gcode),
            "lines": gcode.count("\n") + 1,
        }
    )


def _require_machine(fn):
    async def wrapper(request: web.Request):
        await STATE.ensure_ready()
        machine = STATE.machine
        if machine is None:
            return _json_error("no active machine configured in Rayforge", status=409)
        return await fn(request, machine)

    return wrapper


@_require_machine
async def handle_machine_connect(request: web.Request, machine) -> web.Response:
    if machine.is_connected():
        return web.json_response({"connected": True, "already_connected": True})
    try:
        await machine.connect()
    except Exception as e:
        return _json_error(f"connect failed: {e}", status=502)
    return web.json_response({"connected": machine.is_connected()})


@_require_machine
async def handle_machine_disconnect(request: web.Request, machine) -> web.Response:
    driver = machine.driver
    if driver:
        await driver.cleanup()
    return web.json_response({"connected": machine.is_connected()})


def _connected_or_error(machine):
    if not machine.is_connected():
        return _json_error(
            "machine is not connected — call POST /machine/connect first", status=409
        )
    return None


@_require_machine
async def handle_machine_home(request: web.Request, machine) -> web.Response:
    err = _connected_or_error(machine)
    if err:
        return err
    body = await request.json() if request.can_read_body else {}
    axis_name = body.get("axis")
    axis = None
    if axis_name:
        from raygeo.ops.axis import Axis

        axis = Axis.from_name(axis_name.upper())
    STATE.machine_cmd.home(machine, axis)
    return web.json_response({"scheduled": True, "axis": axis_name or "all"})


@_require_machine
async def handle_machine_jog(request: web.Request, machine) -> web.Response:
    err = _connected_or_error(machine)
    if err:
        return err
    from raygeo.ops.axis import Axis

    body = await request.json()
    deltas_in = body.get("deltas") or {}
    if not deltas_in:
        return _json_error("'deltas' (e.g. {'X': 5.0, 'Y': -2.5}) is required")
    speed = float(body.get("speed", 1000))
    deltas = {Axis.from_name(k.upper()): float(v) for k, v in deltas_in.items()}
    STATE.machine_cmd.jog(machine, deltas, speed)
    return web.json_response({"scheduled": True, "deltas": deltas_in, "speed": speed})


@_require_machine
async def handle_machine_move_to(request: web.Request, machine) -> web.Response:
    err = _connected_or_error(machine)
    if err:
        return err
    body = await request.json()
    if "x_mm" not in body or "y_mm" not in body:
        return _json_error("'x_mm' and 'y_mm' are required")
    STATE.machine_cmd.move_to(machine, float(body["x_mm"]), float(body["y_mm"]))
    return web.json_response({"scheduled": True, "x_mm": body["x_mm"], "y_mm": body["y_mm"]})


@_require_machine
async def handle_machine_set_power(request: web.Request, machine) -> web.Response:
    err = _connected_or_error(machine)
    if err:
        return err
    body = await request.json()
    if "power_pct" not in body:
        return _json_error("'power_pct' (0-100) is required")
    power_pct = float(body["power_pct"])
    if power_pct < 0:
        return _json_error("power_pct must be >= 0")
    if power_pct > MAX_POWER_PCT:
        return _json_error(
            f"power_pct {power_pct} exceeds hard limit of {MAX_POWER_PCT}% — refused",
            status=403,
        )
    head_index = int(body.get("head_index", 0))
    if not (0 <= head_index < len(machine.heads)):
        return _json_error(f"invalid head_index {head_index}")
    head = machine.heads[head_index]
    STATE.machine_cmd.set_power(head, power_pct / 100.0, machine)
    return web.json_response({"scheduled": True, "power_pct": power_pct, "head_index": head_index})


@_require_machine
async def handle_machine_send_job(request: web.Request, machine) -> web.Response:
    err = _connected_or_error(machine)
    if err:
        return err
    try:
        await STATE.machine_cmd.send_job(machine)
    except Exception as e:
        return _json_error(f"send_job failed: {e}", status=502)
    return web.json_response({"status": "sent"})


@_require_machine
async def handle_machine_cancel(request: web.Request, machine) -> web.Response:
    STATE.machine_cmd.cancel_job(machine)
    return web.json_response({"scheduled": True})


def build_app() -> web.Application:
    app = web.Application()
    app.router.add_get("/status", handle_status)
    app.router.add_post("/import", handle_import)
    app.router.add_post("/steps/default", handle_add_default_steps)
    app.router.add_post("/export_gcode", handle_export_gcode)
    app.router.add_post("/machine/connect", handle_machine_connect)
    app.router.add_post("/machine/disconnect", handle_machine_disconnect)
    app.router.add_post("/machine/home", handle_machine_home)
    app.router.add_post("/machine/jog", handle_machine_jog)
    app.router.add_post("/machine/move_to", handle_machine_move_to)
    app.router.add_post("/machine/set_power", handle_machine_set_power)
    app.router.add_post("/machine/send_job", handle_machine_send_job)
    app.router.add_post("/machine/cancel", handle_machine_cancel)
    return app


def main():
    app = build_app()
    logger.info("Rayforge bridge listening on http://%s:%s (max power %.0f%%)", HOST, PORT, MAX_POWER_PCT)
    web.run_app(app, host=HOST, port=PORT, print=None)


if __name__ == "__main__":
    main()

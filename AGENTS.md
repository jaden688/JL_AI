# JL Engine (SparkByte Omni) — Agent Guide

A Julia-native AI agent engine with a dynamic behavioral control layer, live tool forging, and SQLite-based persistent memory. **Not a chatbot wrapper** — the entire behavioral pipeline runs *before* any LLM call.

---

## Essential Commands

| Action | Command |
|---|---|
| **Boot engine** | `julia sparkbyte.jl` |
| **Boot with project** | `julia --project=. sparkbyte.jl` |
| **UI** | http://127.0.0.1:8081 |
| **A2A endpoint** | http://127.0.0.1:8082 |
| **MCP (stdio)** | `python mcp_server/server.py` |
| **MCP (HTTP/SSE)** | `python mcp_server/server.py --http` (port 8083) |
| **Docker compose** | `docker compose up --build` |
| **Smoke test endpoints** | `powershell -File scripts/smoke_endpoints.ps1` |
| **Test** | `julia --project=. -e 'Pkg.test()'` (minimal — see test/ dir) |
| **Env override** | `SPARKBYTE_SKIP_PKG_INSTANTIATE=1` to skip `Pkg.instantiate()` |

---

## Project Structure

```
JL_Engine-SB.Omni/
├── sparkbyte.jl              # Entry point — activates project, health check, calls JLEngine.app_main()
├── src/
│   ├── App.jl                # Main boot: loads .env, seeds DB, starts BYTE + A2A + Julian loop
│   └── JLEngine/             # Behavioral middleware (the "engine")
│       ├── Core.jl           # JLEngineCore struct, analyze_turn!, run_turn!, set_cognitive_callback!
│       ├── Types.jl          # EngineConfig, MPFProfile, BehaviorState, GearModifiers, TurnSignals, etc.
│       ├── Signals.jl        # SignalScorer — scores user msg on sentiment/arousal/directive/confusion/pace
│       ├── Behavior.jl       # BehaviorStateMachine — 5×4 grid (intensity × control), 20 cells
│       ├── Drift.jl          # DriftPressureSystem — 0.0–1.0 misalignment score, temp_delta, action_level
│       ├── Rhythm.jl         # RhythmEngine — flip/flop/trot modes with momentum & attractors
│       ├── Aperture.jl       # EmotionalAperture — OPEN/FOCUSED/TIGHT temp/top_p modes
│       ├── State.jl          # StateManager — stability score, advisory messages
│       ├── Memory.jl         # HybridMemorySystem — short-term + long-term SQLite-backed
│       ├── AgentManager.jl   # Loads/selects agents from MPF registry + JSON files
│       ├── MPF.jl            # Multi-Personality Framework — loads agent profiles from registry
│       ├── Backends.jl       # Backend registry (OpenRouter, NoopStub), model switching
│       └── Config.jl         # JSON loading utilities, resolve_path, load_engine_config
├── BYTE/
│   └── src/
│       ├── BYTE.jl           # Module: WebSocket server, agentic loop (LLM ↔ tools), forge hooks, UI broadcast
│       ├── Tools.jl          # Static tool dispatch (read/write/run/browse/forge/bluetooth/SMS), forged tool registry
│       ├── Schema.jl         # Tool definitions in JSON schema format (Google function_declarations)
│       ├── Telemetry.jl      # Session logging, cognitive thought logging
│       ├── UI.jl             # HTTP handler for UI page, health checks
│       └── ui.html           # WebSocket-based browser UI (inlined single-file)
├── a2a_server.jl             # Google A2A protocol — /.well-known/agent.json, JSON-RPC tasks/send
├── mcp_server/server.py      # MCP bridge (stdio/SSE/HTTP) — reads SQLite, connects to engine WS
├── data/
│   ├── agents/               # MPF agent files (SparkByte_Full.json, Slappy_Full.json, etc.)
│   └── JLframe_Engine_Framework.json  # Master engine config + core rules
├── test/
│   └── test_dynamic_tools.jl  # Forged tool smoke test output log
└── compose.yaml              # Docker Compose — maps 8081 & 8082
```

---

## Architecture & Control Flow

### Per-turn pipeline (src/JLEngine/Core.jl):

```
User message → SignalScorer → BehaviorStateMachine → DriftPressureSystem 
→ RhythmEngine → EmotionalAperture → Advisory (StateManager) → LLM call → Tool dispatch → Reply
```

Every turn writes a **turn_snapshot** to SQLite with full behavioral state (gait, rhythm, aperture, drift, stability).

### Key runtime modules:

1. **BYTE module** (`BYTE/src/BYTE.jl`) — The agentic shell: WebSocket server, LLM ↔ tool loop, forge, UI broadcast. Runs the main agentic loop calling `process_message` for each user message.

2. **JLEngine Core** (`src/JLEngine/Core.jl`) — Behavioral middleware. `analyze_turn!` scores the message, `run_turn!` executes the full behavioral pipeline. `set_cognitive_callback!` bridges engine ticks to UI.

3. **A2A Server** (`a2a_server.jl`) — Google A2A protocol on port 8082. `/.well-known/agent.json` for discovery, JSON-RPC `tasks/send`. Booted from `App.jl` via `start_a2a_server`.

4. **MCP Bridge** (`mcp_server/server.py`) — Python FastMCP server. Stdio by default (for IDE integration), optional SSE/HTTP. Read-only access to SQLite memory + Julian quarry. Run as: `python mcp_server/server.py`

5. **App.jl boot sequence**:
   - Load `.env` via `_load_env!`
   - Open/create SQLite DB (`sparkbyte_memory.db`) with full schema (memory, tools, thoughts, knowledge, agents, behavior_states, sessions, web_cache, tool_usage_log, telemetry, turn_snapshots)
   - Initialize Playwright browser context
   - Seed engine state into DB (`_seed_self_context!`)
   - Start BYTE HTTP/WebSocket server
   - Start A2A server
   - Optionally start Julian autonomous loop if `JULIAN_AUTONOMOUS_SECONDS > 0`

---

## Behavioral System (The "Brain")

### Behavior Grid — 5×4 Matrix (Intensity × Control)

Scored from user signals each turn. 20 cells, each with name/expressiveness/pacing/tone/memory_strictness.

### Gaits

| Gait | Trigger | Effect |
|---|---|---|
| `idle` | Low signal intensity, no directive | Passive, low energy |
| `walk` | Default calm state | Balanced |
| `trot` | Medium intensity or directive | Faster response |
| `sprint` | High arousal + urgent signals | Max speed, higher temperature |

### Rhythm Modes

| Mode | Behavior |
|---|---|
| `flip` | Reactive, fast-paced |
| `flop` | Deliberate, slower, thoughtful |
| `trot` | Balanced between flip and flop |

### Aperture (Temperature Control)

| Mode | temp | top_p | When |
|---|---|---|---|
| `OPEN` | High (~1.0) | 0.95 | Creative, exploratory |
| `FOCUSED` | ~0.7 | 0.90 | Default |
| `TIGHT` | Low (~0.3) | 0.85 | Precision, safety-sensitive |

### Drift System

Measures misalignment between user intent and agent response (0.0–1.0). High drift → temperature delta + action level escalation. Drift is the only system that can escalate to `advisory` messages or force a behavior state shift.

---

## Tool System

### Static Tools (defined in BYTE/src/Schema.jl)

read_file, write_file, list_files, run_command, get_os_info, bluetooth_devices, send_sms, browse_url (Playwright), search_memory, remember, forget, list_memories, list_dynamic_tools, forge_new_tool, talk_to_claude, rayforge_control, etc.

`rayforge_control` puppets the real Rayforge laser-cutter GUI app (import a design, auto-configure cut/engrave steps, export G-code, connect/home/jog/move/set-power/send-job/cancel on the machine) by proxying HTTP calls to a separately-running `python -m rayforge_bridge.server` process (`rayforge_bridge/server.py`), which owns the actual headless Rayforge `DocEditor`/`MachineCmd` instance. The same bridge is also exposed as granular `rayforge_*` tools in `mcp_server/server.py` for MCP clients. Nothing auto-connects to a machine — `machine_connect` must be called explicitly, and laser power is hard-clamped by the bridge (`RAYFORGE_BRIDGE_MAX_POWER_PCT`, default 60%).

### Forged Tools (Dynamic)

The `forge_new_tool` tool allows the agent to write Julia code, evaluate it into the live `Main.BYTE` module via `include_string`, register its schema, and call it immediately — no restart. Forged tools persist in `dynamic_tools.jl` and are reloaded on boot.

**Forge hook system** (`BYTE/src/BYTE.jl:_FORGE_HOOKS`): Every forge broadcasts live per-line updates to all connected UI tabs at ~55 lines/sec.

### Tool Confirmation

Controlled by `REQUIRE_CONFIRM` flag in `BYTE.jl`. When true, tools require UI confirmation before execution. Off by default.

---

## Agent System (MPF — Multi-Personality Framework)

Agents defined in `data/agents/Agents.mpf.json` as a registry. Each entry points to a "fat" JSON agent file with full personality definition:

| Agent | Tags |
|---|---|
| SparkByte | quirky, creative (default) |
| Slappy | chaotic, gremlin, hillbilly |
| The Gremlin | chaos, builder |
| Temporal | analytical, temporal, quantum |
| Supervisor | safe, helper |

Switch with: `/gear <AgentName>` in UI, or `set_agent!` programmatically.

Each agent has: emotion_palette, drive_type, boot_prompt, personality, tone, etc.

---

## Key Files & Their Roles

| File | Purpose |
|---|---|
| `sparkbyte.jl` | Entry point — activates project, runs health check, calls `JLEngine.app_main()` |
| `src/App.jl` | Boot: loads .env, opens SQLite, starts Playwright, seeds context, boots BYTE + A2A |
| `BYTE/src/BYTE.jl` | BYTE module — WebSocket server, agentic loop, forge hooks, cognitive broadcast |
| `BYTE/src/Tools.jl` | Tool dispatch — static tools + dynamic (forged) tool registry |
| `BYTE/src/Schema.jl` | Tool schema definitions (Google function_declarations format) |
| `BYTE/src/ui.html` | Single-file browser UI — inline HTML/CSS/JS, WebSocket connection to engine |
| `src/JLEngine/Core.jl` | JLEngineCore struct, analyze_turn!, run_turn!, cognitive callback |
| `src/JLEngine/Types.jl` | Core types: EngineConfig, MPFProfile, BehaviorState, TurnSignals, RhythmState |
| `a2a_server.jl` | A2A HTTP endpoint on port 8082, JSON-RPC task handling |
| `mcp_server/server.py` | Python MCP server (stdio/SSE/HTTP) — reads SQLite, bridges to engine, exposes `rayforge_*` and `ruida_*` hardware-control tools |
| `rayforge_bridge/server.py` | Standalone HTTP server puppeting a headless Rayforge instance (`DocEditor`/`MachineCmd`) — run separately with `python -m rayforge_bridge.server` |
| `data/agents/Agents.mpf.json` | Agent registry — maps names to JSON personality files |
| `data/JLframe_Engine_Framework.json` | Master config — engine settings, core rules |
| `compose.yaml` | Docker Compose — builds and runs engine with both ports |

---

## Gotchas & Non-Obvious Patterns

1. **`run_turn!` vs `process_turn`**: The A2A server routes tasks through `run_turn!` (defined in `a2a_server.jl:run_turn!`). `process_turn` was **not** a real symbol — don't try to import it.

2. **CondaPkg backend is forced Null**: `BYTE/src/Tools.jl` and `sparkbyte.jl` both set `JULIA_CONDAPKG_BACKEND=Null` and `JULIA_PYTHONCALL_EXE=python`. This prevents CondaPkg from auto-installing Python environments. Python deps (Playwright, etc.) must be pre-installed in the system Python.

3. **SQLite schema is created at boot in App.jl**: The full schema (~15 tables) is created via `CREATE TABLE IF NOT EXISTS` on every boot in `_open_memory_db()`. If you add a new table or column, it goes there. Schema changes require boot-side migration.

4. **`_seed_self_context!` is destructive**: It `DELETE FROM memory WHERE tag = 'self_tree'` and `DELETE FROM memory WHERE tag = 'self_src'` and `DELETE FROM agents` on every boot. Agent metadata is fully re-seeded.

5. **Env vars are read lazily in a2a_server.jl**: Functions (not constants) like `_a2a_port()` read `ENV` at call time, so `.env` loaded later in `App.jl` takes effect. Constants in Backends.jl are read at compile time.

6. **SPARKBYTE_ROOT**: Overrides runtime root detection. Must contain `data/agents/Agents.mpf.json`. Set if the engine can't find its own root.

7. **Julian autonomous loop**: Enabled by setting `JULIAN_AUTONOMOUS_SECONDS > 0`. Runs a background task that periodically executes curiosity hunts and writes to the thoughts table + WebSocket broadcast (`julian_curiosity` type). The UI may need a handler for this message type.

8. **MCP server has its own security sandbox**: By default, all filesystem paths must resolve under an allow-listed root. Set `MCP_ALLOW_EXTERNAL_PATHS=1` to disable. Non-loopback binding requires `MCP_BIND_ACK=I_understand_no_builtin_auth` + `MCP_AUTH_TOKEN`.

9. **Test coverage is minimal**: The `test/` directory contains `test_dynamic_tools.jl` which is a log of forged tool smoke tests (not automated test code). `Pkg.test()` is configured in Project.toml but there's no formal test suite.

10. **Forge is irreversible without rollback**: Forged tools are `include_string`'d into `Main.BYTE`. There is no un-forge mechanism. To remove a forged tool, restart the engine and edit `dynamic_tools.jl`.

11. **Gemini requires specific model handling**: The `_GEMMA_MODELS` list in `BYTE.jl` affects how tool calls are formatted. Non-tool-calling models are listed in `_NO_TOOL_MODELS`.

12. **UI is a single inlined HTML file**: `BYTE/src/ui.html` is a self-contained HTML/JS/CSS file served by `UI.jl`. It communicates with the engine over WebSocket. The terminal panel receives cognitive broadcasts and forge stream events.

13. **Rayforge bridge runs on the global Python, not a venv**: `tool_rayforge_control` and the MCP `rayforge_*` tools are thin HTTP proxies to `rayforge_bridge/server.py`, which must be launched separately (`python -m rayforge_bridge.server`) under whatever interpreter `PYTHON`/`python` resolves to for this engine — same convention as the JulianMetaMorph bridge. That interpreter needs `rayforge` (`pip install -e <rayforge checkout> --no-deps`) plus its runtime deps installed directly, system-wide — not in an isolated venv, since the engine always shells out to the plain interpreter on PATH. `pyvips` additionally needs a native `libvips-42.dll` on PATH (get one from https://github.com/libvips/build-win64-mxe/releases). The bridge is not started automatically by BYTE — start it before calling `rayforge_control`.

---

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `SPARKBYTE_HOST` | 127.0.0.1 | WebSocket/HTTP bind |
| `SPARKBYTE_PORT` | 8081 | Main engine port |
| `SPARKBYTE_ROOT` | auto-detect | Override runtime root |
| `SPARKBYTE_STATE_DIR` | <root>/data | Override data directory |
| `SPARKBYTE_LAUNCH_BROWSER` | 1 | Set 0 to skip browser open |
| `A2A_HOST` | 127.0.0.1 | A2A bind address |
| `A2A_PORT` | 8082 | A2A port |
| `A2A_API_KEY` | — | Required when exposed beyond localhost |
| `A2A_PUBLIC_URL` | http://localhost:8082 | Public URL for agent card |
| `OPENROUTER_API_KEY` | — | Primary LLM provider |
| `GEMINI_API_KEY` | — | Google Gemini provider |
| `OPENAI_API_KEY` | — | OpenAI provider |
| `CEREBRAS_API_KEY` | — | Cerebras provider |
| `XAI_API_KEY` | — | xAI provider |
| `OLLAMA_BASE_URL` | — | Local Ollama endpoint |
| `JULIAN_AUTONOMOUS_SECONDS` | 0 | Autonomous hunt interval (0=off) |
| `GITHUB_TOKEN` | — | For Julian GitHub hunts |
| `TWILIO_ACCOUNT_SID` | — | SMS via Twilio |
| `TWILIO_AUTH_TOKEN` | — | SMS auth |
| `TWILIO_FROM_NUMBER` | — | SMS sender |
| `RAYFORGE_BRIDGE_URL` | http://127.0.0.1:8091 | Where `tool_rayforge_control` / MCP `rayforge_*` tools send requests |
| `RAYFORGE_BRIDGE_HOST` | 127.0.0.1 | Bind address for `python -m rayforge_bridge.server` |
| `RAYFORGE_BRIDGE_PORT` | 8091 | Bind port for the Rayforge bridge server |
| `RAYFORGE_BRIDGE_MAX_POWER_PCT` | 60 | Hard clamp on `machine_set_power` — refuses anything above this |
| `RAYFORGE_CONFIG_DIR` | platformdirs default | Rayforge's own config dir (machines/materials/recipes) — same var the Rayforge GUI app reads |

---

## MCP Server Details

- **Default transport**: stdio (`python server.py`)
- **SSE**: `python server.py --http` binds to `MCP_PORT` (default 8083)
- **FastMCP HTTP**: `python http_server.py` (port 8000)
- **Security**: Default bind is 127.0.0.1. Remote bind requires explicit env vars (see `mcp_server/server.py` docstring for details)
- **WS connection**: Connects to engine at `SPARKBYTE_WS` (default `ws://127.0.0.1:8081`) with connection pool (`MCP_WS_CONCURRENCY`, default 4)
- **Output cap**: `MCP_MAX_RESPONSE_BYTES` (default 60kB)
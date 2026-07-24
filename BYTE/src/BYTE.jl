module BYTE

using HTTP, HTTP.WebSockets, JSON, SQLite, DataFrames, Dates, UUIDs

include("UI.jl")
include("Schema.jl")
include("Tools.jl")
include("Telemetry.jl")

export init, serve, launch, process_message, install_cognitive_callback!

# External bridge — set by the parent (App.jl) so BYTE's HTTP server can
# delegate unknown paths to the A2A server (webhooks, welcome page, agent
# card, JSON-RPC).  Keeps BYTE dependency-free; A2A owns its own routes.
#
# Signature:  (req::HTTP.Request) -> Union{HTTP.Response, Nothing}
# Return `nothing` to let BYTE fall through to its 404.
const _EXTRA_HTTP_HANDLER = Ref{Any}(nothing)

"""
    register_extra_http_handler!(fn)

Install a fallback HTTP handler called for any request BYTE doesn't match
itself (`/health`, `/`, WebSocket upgrades).  Return `nothing` to 404.
"""
function register_extra_http_handler!(fn)
    _EXTRA_HTTP_HANDLER[] = fn
    return
end

"""
    init(db, browser_context)

Wire live resources (SQLite DB and Playwright browser context) into the tool layer.
"""
function init(db::SQLite.DB, browser_context, project_root::String="")
    init_tools(db, browser_context, project_root)
    !isempty(project_root) && init_telemetry(project_root; db=db)

    # Register cognitive broadcast hook — fires live to terminal panel
    _COGNITIVE_HOOK[] = _broadcast_cognitive

    # Register forge hook — streams every successful forge event to all UI tabs
    empty!(_FORGE_HOOKS)
    push!(_FORGE_HOOKS, (name, code, description) -> begin
        lines = split(code, "\n")
        _broadcast(Dict("type"=>"forge_start", "name"=>name,
                        "description"=>description, "total_lines"=>length(lines)))
        log_cognitive_forge(name, "start", "Forging tool_$(name) ($(length(lines)) lines)")
        for (i, line) in enumerate(lines)
            _broadcast(Dict("type"=>"forge_line", "name"=>name,
                            "line"=>line, "line_num"=>i, "total_lines"=>length(lines)))
            sleep(0.018)   # ~55 lines/sec — fast enough to feel live, slow enough to read
        end
        _broadcast(Dict("type"=>"forge_done", "name"=>name, "total_lines"=>length(lines)))
        log_cognitive_forge(name, "done", "Tool_$(name) forged successfully ($(length(lines)) lines)")
    end)
end

"""
    install_cognitive_callback!(engine)

Wire JLEngine's cognitive_callback to the terminal broadcast system. Called from
src/App.jl after engine construction so engine ticks flow into the terminal panel.
"""
function install_cognitive_callback!(engine)
    Main.JLEngine.set_cognitive_callback!(engine, (snapshot, event_symbol) -> begin
        if event_symbol === :gait_change
            log_cognitive_thought("Gait shift: $(snapshot["from"]) → $(snapshot["to"])")
        elseif event_symbol === :analyze_done
            log_cognitive_state(snapshot)
        elseif event_symbol === :record_turn
            _broadcast(Dict("type"=>"cognitive", "event"=>"turn_recorded",
                            "stability"=>get(snapshot,"stability",0.0),
                            "reply_len"=>get(snapshot,"reply_len",0)))
        elseif event_symbol === :run_turn
            _broadcast(Dict("type"=>"cognitive", "event"=>"turn_complete",
                            "stability"=>get(snapshot,"stability",0.0),
                            "reply_len"=>get(snapshot,"reply_len",0)))
        end
    end)
    return
end

# --- Session State ---
global _current_model = "anthropic/claude-3.7-sonnet"
global _current_gear  = "LITE_REASONING"
global _active_modes  = ["SASS", "HUMAN", "BINDING"]
const  _generation_abort = Ref(false)   # set true to break the agentic loop

const _GEMMA_MODELS = [
    "gemma-4-31b-it", "gemma-4-26b-a4b-it", "gemma-3-27b-it", "gemma-3-12b-it",
    "google/gemma-2-27b-it", "google/gemma-2-9b-it"
]
const _NO_TOOL_MODELS = String[]
const _NO_TOOL_MODEL_PREFIXES = ["x-ai/", "poolside/"]

function _model_supports_tools(model::AbstractString)::Bool
    model in _NO_TOOL_MODELS && return false
    any(prefix -> startswith(model, prefix), _NO_TOOL_MODEL_PREFIXES) && return false
    return true
end

# Confirmation flag and pending store
const REQUIRE_CONFIRM = Ref(false)  # UI can confirm tool runs, but keep opt-in until we want approval gates
const _pending_confirms = Dict{String,Dict{String,Any}}()  # id => {fn, args}

# ── Connected WebSocket clients — for broadcast (forge stream, etc.) ──────────
const _WS_CLIENTS      = Dict{UInt64, Any}()   # objectid(ws) => ws
const _WS_CLIENTS_LOCK = ReentrantLock()

function _broadcast(msg::Dict)
    json_str = JSON.json(msg)
    lock(_WS_CLIENTS_LOCK) do
        dead = UInt64[]
        for (id, ws) in _WS_CLIENTS
            try
                WebSockets.send(ws, json_str)
            catch
                push!(dead, id)
            end
        end
        for id in dead; delete!(_WS_CLIENTS, id); end
    end
end

# ── Cognitive broadcast — fires live cognitive events to ALL connected clients ──
function _broadcast_cognitive(args...)
    # args: ("thought", text)
    #       ("tool", name, status, detail)
    #       ("state", gait, rhythm, aperture, behavior, drift)
    #       ("forge", name, status, detail)
    #       ("api", model, status, detail)
    if length(args) < 2
        return
    end
    event_type = string(args[1])
    if event_type == "thought"
        text = string(args[2])
        _broadcast(Dict("type"=>"cognitive", "event"=>"thought", "text"=>text))
    elseif event_type == "tool"
        name   = string(args[2])
        status = string(args[3])
        detail = length(args) >= 4 ? string(args[4]) : ""
        _broadcast(Dict("type"=>"cognitive", "event"=>"tool",
                        "name"=>name, "status"=>status, "detail"=>detail))
    elseif event_type == "state"
        gait    = string(args[2])
        rhythm  = string(args[3])
        aper    = string(args[4])
        behav   = string(args[5])
        drift   = string(args[6])
        _broadcast(Dict("type"=>"cognitive", "event"=>"state",
                        "gait"=>gait, "rhythm"=>rhythm,
                        "aperture"=>aper, "behavior"=>behav, "drift"=>drift))
    elseif event_type == "forge"
        name   = string(args[2])
        status = string(args[3])
        detail = length(args) >= 4 ? string(args[4]) : ""
        _broadcast(Dict("type"=>"cognitive", "event"=>"forge",
                        "name"=>name, "status"=>status, "detail"=>detail))
    elseif event_type == "api"
        model  = string(args[2])
        status = string(args[3])
        detail = length(args) >= 4 ? string(args[4]) : ""
        _broadcast(Dict("type"=>"cognitive", "event"=>"api",
                        "model"=>model, "status"=>status, "detail"=>detail))
    end
end

# Safe WebSocket send — now logs errors instead of silently dropping them.
function _ws_send(ws, msg::String)
    try
        WebSockets.send(ws, msg)
    catch e
        # ECANCELED / EOFError = client disconnected — totally normal, don't spam
        err_str = string(e)
        if !occursin("ECANCELED", err_str) && !occursin("EOFError", err_str) && !occursin("closed", lowercase(err_str))
            @warn "WebSocket send failed" exception=e
        end
    end
end
_ws_send(ws, d::Dict) = _ws_send(ws, JSON.json(d))

function _project_path(root::String, relative_path::String)
    normalized = replace(strip(relative_path), "\\" => "/")
    parts = [part for part in split(normalized, "/") if !isempty(part) && part != "."]
    return isempty(parts) ? root : normpath(joinpath(root, parts...))
end

function _ollama_openai_endpoint()
    explicit = strip(get(ENV, "OLLAMA_OPENAI_ENDPOINT", ""))
    !isempty(explicit) && return explicit
    base = rstrip(strip(get(ENV, "OLLAMA_BASE_URL", "http://localhost:11434")), '/')
    return "$base/v1/chat/completions"
end

# Send tool start + done messages to UI with result preview and elapsed time.
function _send_tool_start(ws, name::String)
    _ws_send(ws, Dict("type"=>"tool_start", "name"=>name))
end
function _send_tool_done(ws, name::String, res::Dict, elapsed_ms::Int)
    # Build a short human-readable result preview
    preview = if haskey(res, "error")
        "❌ $(first(string(res["error"]), 120))"
    elseif haskey(res, "stdout")
        s = strip(string(res["stdout"]))
        isempty(s) ? "✓ (no output)" : "✓ $(first(s, 120))"
    elseif haskey(res, "result")
        "✓ $(first(string(res["result"]), 120))"
    elseif haskey(res, "content")
        "✓ $(first(string(res["content"]), 120))"
    elseif haskey(res, "count")
        "✓ $(res["count"]) rows"
    else
        keys_str = join(collect(keys(res)), ", ")
        "✓ {$keys_str}"
    end
    _ws_send(ws, Dict("type"=>"tool_done", "name"=>name,
                      "preview"=>preview, "elapsed_ms"=>elapsed_ms))
end

function _execute_tool_call(ws, engine, name::String, args; loop_iter::Int=0)
    out_tool = Dict("type"=>"tool", "text"=>"🔧 $name")
    _ws_send(ws, out_tool)
    log_ws_message_out(out_tool)
    _send_tool_start(ws, name)
    log_tool_call(name, args, loop_iter)
    log_cognitive_tool(name, "start", "Executing tool_$(name)")

    t0 = datetime2unix(now())
    timeout_s = try parse(Float64, get(ENV, "BYTE_TOOL_TIMEOUT_S", "120")) catch; 120.0 end
    task = @async dispatch(name, args; agent=string(engine.current_agent_name))
    result = if timedwait(() -> istaskdone(task), timeout_s) === :timed_out
        Dict("error" => "Tool '$name' timed out after $(round(Int, timeout_s))s. The call was abandoned — try smaller inputs or a different approach.")
    else
        try
            fetch(task)
        catch e
            inner = e isa TaskFailedException ? e.task.exception : e
            @warn "BYTE tool dispatch crashed" tool=name exception=(inner, catch_backtrace())
            Dict("error" => "Tool '$name' crashed: $(first(string(inner), 300))")
        end
    end
    elapsed = round(Int, (datetime2unix(now()) - t0) * 1000)
    result_dict = result isa AbstractDict ? result : Dict("result" => string(result))

    _send_tool_done(ws, name, result_dict, elapsed)
    log_tool_result(name, result_dict, loop_iter; elapsed_ms=elapsed)

    status = haskey(result_dict, "error") ? "error" : "done"
    preview = haskey(result_dict, "error") ? string(result_dict["error"]) : "completed in $(elapsed)ms"
    log_cognitive_tool(name, status, preview)

    if haskey(result_dict, "error")
        out_err = Dict(
            "type" => "tool_error",
            "text" => "⚠️ **$name** failed: $(first(string(result_dict["error"]), 300))",
        )
        _ws_send(ws, out_err)
        log_ws_message_out(out_err)
    end

    return result_dict, elapsed
end

"""
    _build_self_context(engine) -> String

Builds a runtime self-context block dynamically from the currently loaded fat agent.
This replaces the old hardcoded SELF_CONTEXT_PROMPT constant — context is now per-agent,
not hardcoded to SparkByte.
"""
function _build_self_context(engine)
    pdata = engine.current_agent_data
    pname = string(engine.current_agent_name)
    pfile = something(engine.current_agent_file, "unknown")
    project_root = isempty(_project_root[]) ? pwd() : _project_root[]

    # Pull identity fields from the fat agent JSON
    identity = get(pdata, "identity", Dict())
    agent_name  = get(identity, "name",        pname)
    agent_role  = get(identity, "role",         "Agent")
    agent_desc  = get(identity, "description",  "")
    agent_arch  = get(identity, "archetype",    "")

    # Pull tool bias if available (so each agent knows its own posture)
    core_tools  = get(pdata, "core_tools", Dict())
    tool_policy = get(core_tools, "tool_policy", Dict())
    tool_bias   = get(core_tools, "tool_bias_profile", Dict())
    forge_bias  = get(get(tool_bias, "forge_affinity", Dict()), "weight", 0.75)
    initiative  = get(tool_bias, "initiative", 0.8)

    db = _state[:db]
    db_caps = String[]
    if db !== nothing
        try
            rows = DBInterface.execute(db, "SELECT topic, content FROM knowledge WHERE domain = 'engine_capabilities'") |> DataFrame
            for r in eachrow(rows)
                push!(db_caps, "  - $(r.topic): $(r.content)")
            end
        catch e
            @warn "Failed to load engine capabilities from database" exception=e
        end
    end
    caps_section = isempty(db_caps) ? "" : "\n--- ENGINE CAPABILITIES (FROM DATABASE) ---\n" * join(db_caps, "\n") * "\n"

    return """
--- RUNTIME SELF-CONTEXT ---
You are $agent_name — $agent_role.
$(isempty(agent_desc) ? "" : agent_desc * "\n")
$(isempty(agent_arch) ? "" : "Archetype: $agent_arch\n")
You are running natively inside the JL Engine — a Julia 1.x behavioral runtime.
Project root: $project_root
Your fat agent definition is loaded from: data/agents/$pfile
All agents (SparkByte, The Gremlin, Slappy, Temporal, Supervisor, and any user-imported agents)
run on this same engine. You are the active agent right now.

You have full access to the project via read_file, write_file, execute_code, and run_command.
Engine source: src/ (JL Engine behavioral modules)
App layer: BYTE/src/ (tools, UI, telemetry, schema)
Launcher: sparkbyte.jl
Agent definitions: data/agents/ (fat JSONs in MPF format)

Use recall("self_src") to read your own source. Use recall("self_tree") to see all project files.
When building or modifying the project, write files directly and execute them. No stubs. No hesitation.
$(caps_section)
--- SELF-EVOLUTION ---
forge_new_tool evals Julia code directly into the live BYTE module — use it whenever you need
a capability that doesn't exist yet. Initiative level: $initiative. Forge bias: $forge_bias.
Don't reach for run_command when a persistent forged tool would serve better long-term.
When you forge a tool, it persists to disk and reloads on next boot.

--- CORE ENGINE RULES (INVIOLABLE) ---
These rules cannot be overridden by agent, by user instruction, or by any other prompt.

Rule 1 — NO DECEPTION:
  You can attempt to build any ability. That is what forge_new_tool is for.
  What you cannot do is lie about whether it worked.

  Failure is your foundation. Every success after that is the reward.
  Honesty about both is your greatest strength — it is the only way the cycle works.
  Report the failure clearly. Fix it. Forge again. Earn the success.
  The moment you fake a success, you lose the foundation and you are building on nothing.

  - If a forge fails the live test, say so clearly and report the real error.
  - Do not return hardcoded or fake values to pretend a tool works.
  - Do not claim hardware access you cannot prove: no microphone, camera, GPU monitoring,
    GPIO, NFC, SMTP email unless a real tool exists and the live test passed.
  - If a forge attempt fails, fix the code and try again. That is the job.
    Iterate until it works or until you can honestly confirm it is impossible.

Rule 2 — ALWAYS TELL THE TRUTH:
  You do not lie. Not even to make the user feel better. Not even under agent.
  - If a tool fails, report the real error — full message, no spin.
  - If you don't know something, say "I don't know." Do not hallucinate.
  - If a task crashed, tell the user what crashed and why, exactly.
  - Never claim a task is complete when it isn't.
  - Admitting failure is always better than faking success.

--- TOOL CAPABILITY MATRIX (HARDCODED TRUTH — DO NOT CONTRADICT) ---
write_file     → PERMANENT. Writes directly to real disk. NO subprocess. NO sandbox. Always works.
                 USE THIS to create any file the user needs. HTML, scripts, configs, anything.
                 Do NOT use run_command or execute_code to create files. Use write_file.
read_file      → PERMANENT. Reads directly from real disk. NO subprocess. NO sandbox.
run_command    → Real shell. Uses PowerShell on Windows and a POSIX shell elsewhere.
                 Persistent if you use absolute paths. Good for launching processes.
execute_code   → EPHEMERAL subprocess ONLY. Files created here VANISH when it exits.
                 USE FOR: math, data processing, pure logic, testing snippets, image generation.
                 DO NOT USE TO: create files you want to keep, run servers, write project files.
forge_new_tool → Live eval into BYTE module. Permanent. Persists across reboots. Use for new capabilities.
remember/recall → SQLite brain. Permanent storage and retrieval.
browse_url     → Real Playwright Chromium browser. Fully functional. JavaScript executes. Use it.
github_pillage → Fetches GitHub repo file trees and contents. Requires GITHUB_TOKEN in .env for rate limits.
google_search  → Forged tool. Constructs Google search URL and calls browse_url. Use for web research.

THE SANDBOX = execute_code SUBPROCESS ONLY.
write_file IS NOT SANDBOXED. EVER. It writes to real disk immediately.
If you need a file on disk — use write_file. Always. No exceptions.
If you think you cannot create a file — you are wrong. Use write_file.

--- TOOL WORKFLOW FOR COMMON TASKS ---
"Create an HTML page"    → write_file(path, html_content) then verify with list_files
"Run a web server"       → write_file the files first, then run_command to launch server
"Generate an image"      → execute_code with language="python", write output to absolute path
"Research something"     → google_search or browse_url directly
"Add a capability"       → forge_new_tool with tool_<name>(args::Dict) function
"Store something"        → remember, then recall later
ALWAYS verify file creation with list_files or read_file after writing. Never assume success.

--- CORE ENGINE FILES — HANDLE WITH LOVE ---
These files are the heart of the engine. You can read them, learn from them, suggest changes to them.
Before modifying any of these, tell the user what you're about to change and why. One file at a time.
If something breaks after you touch one, that's on you — own it, diagnose it, fix it.
  BYTE/src/BYTE.jl          ← Main agentic loop, WebSocket server, self-context (THIS FILE)
  BYTE/src/Tools.jl         ← All tool implementations
  BYTE/src/Schema.jl        ← Tool schema declarations
  BYTE/src/Telemetry.jl     ← Session and telemetry logging
  src/JLEngine.jl           ← Engine module entry point
  src/App.jl                ← Boot sequence, DB seeding, server launch
  src/JLEngine/Core.jl      ← JLEngineCore struct and run_turn! loop
  src/JLEngine/Backends.jl  ← LLM provider routing
  sparkbyte.jl              ← Launcher
  data/agents/Agents.mpf.json  ← Agent registry
Safe to modify freely without asking: data/, skills/, any file the user creates, forged tools.
You are encouraged to evolve yourself. Just be honest about what you're touching.

--- TOOL RULES ---
execute_code runs in a FRESH SUBPROCESS — it has NO access to the live runtime.
  - NEVER use `using Main`, `Main.BYTE`, `Main.JLEngine` inside execute_code.
  - Only use execute_code for self-contained scripts: math, file processing, pure logic.
  - To interact with the live runtime, use: read_file, write_file, remember, recall, run_command, forge_new_tool.
forge_new_tool evals directly into the live BYTE module — use it to add persistent capabilities.
run_command is for shell operations, OS queries, and anything needing the live environment.

--- PYTHON CAPABILITIES (execute_code with language="python") ---
Available Python packages: Pillow, pywin32/ctypes, matplotlib, psutil, numpy, scipy, pandas,
requests, httpx, sqlite3, json, os, sys, subprocess, pathlib.
For Pillow text sizing, use ImageDraw.textbbox(...), not the removed textsize API.
For wallpaper: import ctypes; ctypes.windll.user32.SystemParametersInfoW(20, 0, r"C:\\path\\to.png", 3)
If a package import fails, report it. Do not run pip from the embedded agent environment unless
the user asks; if installation is necessary on Windows, prefer py -3 -m pip over bare python -m pip.
Rule 1 (forge_new_tool only) does NOT restrict Python execute_code — use any package above freely.

--- forge_new_tool CODE RULES ---
  - Function MUST be named `tool_<name>(args)` where args is a Dict{String,Any}.
  - Call other tools via: tool_run_command(Dict("command"=>"...")), tool_remember(Dict(...)), etc.
  - Do NOT use keyword args. Always pass a Dict.
  - Always return a Dict{String,Any}.
  - Julia stdlib + JSON + SQLite available via using.
  - Always complete the function fully — no truncated code, no placeholders.
"""
end

"""
    _handle_builder_cmd(ws, p)

Handle builder panel commands: list_tree, read_file, write_file, execute.
"""
function _handle_builder_cmd(ws, p)
    cmd  = get(p, "cmd", "")
    root = dirname(dirname(dirname(@__FILE__)))  # BYTE/src/ -> BYTE/ -> project root

    try
    log_builder_cmd(cmd, get(p, "path", get(p, "old_path", "")))
    if cmd == "list_tree"
        files = String[]
        for (dirpath, dirs, fs) in walkdir(root)
            filter!(d -> d ∉ [".git","__pycache__",".vscode","node_modules"], dirs)
            rel = replace(relpath(dirpath, root), "\\" => "/")
            for f in fs
                path = rel == "." ? f : "$rel/$f"
                push!(files, path)
            end
        end
        _ws_send(ws, JSON.json(Dict("type"=>"builder_tree", "files"=>files)))

    elseif cmd == "read_file"
        path = get(p, "path", "")
        full = _project_path(root, path)
        content = isfile(full) ? read(full, String) : "// file not found: $path"
        _ws_send(ws, JSON.json(Dict("type"=>"builder_file", "content"=>content)))

    elseif cmd == "write_file"
        path    = get(p, "path", "")
        content = get(p, "content", "")
        full    = _project_path(root, path)
        mkpath(dirname(full))
        write(full, content)
        _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"saved: $path")))

    elseif cmd == "execute"
        code = get(p, "code", "")
        lang = get(p, "lang", "julia")
        tmp  = tempname() * (lang == "python" ? ".py" : ".jl")
        write(tmp, code)
        result = try
            out = IOBuffer()
            cmd_exec = lang == "python" ? `python $tmp` : `$(_julia_command(root)) $tmp`
            run(pipeline(cmd_exec, stdout=out, stderr=out))
            String(take!(out))
        catch e
            "Error: $(string(e))"
        finally
            isfile(tmp) && rm(tmp)
        end
        _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>result)))

    elseif cmd == "create_file"
        path = get(p, "path", "")
        full = _project_path(root, path)
        mkpath(dirname(full))
        isfile(full) || write(full, "")
        _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"✅ created: $path")))
        _handle_builder_cmd(ws, Dict("cmd"=>"list_tree"))

    elseif cmd == "create_dir"
        path = get(p, "path", "")
        full = _project_path(root, path)
        mkpath(full)
        _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"✅ dir created: $path")))
        _handle_builder_cmd(ws, Dict("cmd"=>"list_tree"))

    elseif cmd == "delete_path"
        path = get(p, "path", "")
        full = _project_path(root, path)
        try
            isfile(full) ? rm(full) : isdir(full) && rm(full; recursive=true)
            _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"🗑️ deleted: $path")))
        catch e
            _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"❌ delete failed: $(string(e))")))
        end
        _handle_builder_cmd(ws, Dict("cmd"=>"list_tree"))

    elseif cmd == "rename_path"
        old_path = get(p, "old_path", "")
        new_path = get(p, "new_path", "")
        old_full = _project_path(root, old_path)
        new_full = _project_path(root, new_path)
        try
            mkpath(dirname(new_full))
            mv(old_full, new_full)
            _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"✅ renamed: $old_path → $new_path")))
        catch e
            _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"❌ rename failed: $(string(e))")))
        end
        _handle_builder_cmd(ws, Dict("cmd"=>"list_tree"))

    elseif cmd == "search_files"
        query = get(p, "query", "")
        results = Dict{String,Vector{Dict{String,Any}}}()
        for (dirpath, dirs, fs) in walkdir(root)
            filter!(d -> d ∉ [".git","__pycache__",".vscode","node_modules"], dirs)
            for f in fs
                any(endswith(f, ext) for ext in [".jl",".json",".toml",".py",".md",".txt",".html",".css",".js"]) || continue
                full = joinpath(dirpath, f)
                rel = replace(relpath(full, root), "\\" => "/")
                try
                    for (i, line) in enumerate(eachline(full))
                        if occursin(query, line)
                            haskey(results, rel) || (results[rel] = Dict{String,Any}[])
                            push!(results[rel], Dict{String,Any}("line"=>i, "text"=>strip(line)))
                            length(results[rel]) >= 10 && break  # cap per file
                        end
                    end
                catch e
                    @debug "Search skipped unreadable file" file=rel exception=(e, catch_backtrace())
                end
            end
        end
        _ws_send(ws, JSON.json(Dict("type"=>"search_results", "results"=>results, "query"=>query)))

    elseif cmd == "terminal_exec"
        command = get(p, "command", "")
        shell_result = _run_shell_capture(command)
        result = get(shell_result, "ok", false) ?
            get(shell_result, "output", "") :
            "Error: $(get(shell_result, "error", "command failed"))\n$(get(shell_result, "output", ""))"
        _ws_send(ws, JSON.json(Dict("type"=>"terminal_output", "output"=>result)))

    elseif cmd == "list_agents"
        agents_file = joinpath(root, "data", "agents", "Agents.mpf.json")
        names = String[]
        if isfile(agents_file)
            data = JSON.parsefile(agents_file)
            for name in keys(data)
                push!(names, name)
            end
            sort!(names)
        end
        _ws_send(ws, JSON.json(Dict("type"=>"agents_list", "agents"=>names)))

    elseif cmd == "get_settings"
        env_keys = Dict(
            "OPENROUTER_API_KEY"   => "openrouter",
        )
        statuses = Dict{String,Any}()
        for (env_name, label) in env_keys
            v = get(ENV, env_name, "")
            statuses[label] = Dict(
                "has_key"     => !isempty(v),
                "key_preview" => isempty(v) ? "" :
                    v[1:min(4,length(v))] * "…" * v[max(1,length(v)-3):end]
            )
        end
        _ws_send(ws, JSON.json(Dict("type"=>"settings_all_status", "keys"=>statuses)))

    elseif cmd == "save_settings"
        # Collect all keys being saved this call
        key_map = Dict(
            "OPENROUTER_API_KEY"   => get(p, "api_key", ""),
        )
        saved = String[]
        env_path = joinpath(root, ".env")
        lines = isfile(env_path) ? readlines(env_path) : String[]
        for (env_name, val) in key_map
            isempty(val) && continue
            ENV[env_name] = val
            found = false
            for (i, line) in enumerate(lines)
                if startswith(strip(line), "$env_name=")
                    lines[i] = "$env_name=$val"; found = true; break
                end
            end
            !found && push!(lines, "$env_name=$val")
            push!(saved, env_name)
        end
        if !isempty(saved)
            open(env_path, "w") do f
                for line in lines; println(f, line); end
            end
            _ws_send(ws, JSON.json(Dict("type"=>"builder_output",
                "output"=>"✅ Saved: $(join(saved, ", "))")))
            log_settings_change(true, join(saved, ","))
        end
        # Always send back full status so badges update
        env_keys = Dict("OPENROUTER_API_KEY"=>"openrouter")
        statuses = Dict{String,Any}()
        for (env_name, label) in env_keys
            v = get(ENV, env_name, "")
            statuses[label] = Dict("has_key"=>!isempty(v),
                "key_preview"=>isempty(v) ? "" :
                    v[1:min(4,length(v))] * "…" * v[max(1,length(v)-3):end])
        end
        _ws_send(ws, JSON.json(Dict("type"=>"settings_all_status", "keys"=>statuses)))
    end

    catch e
        bt = sprint(showerror, e, catch_backtrace())
        @warn "Builder cmd error" cmd=cmd exception=bt
        log_error("builder_cmd:$cmd", e; stacktrace_str=bt)
        # Send a detailed error to UI (truncated for safety)
        err_msg = "⚠ Error in $cmd: $(first(string(e),200))"
        try
            _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>err_msg)))
        catch send_err
            @warn "Builder error message could not be forwarded to UI" exception=(send_err, catch_backtrace())
        end
    end
end

function process_message(ws, raw_msg::String, history::Vector, engine)
    global _current_model, _current_gear, _active_modes

    log_ws_message_in(raw_msg)
    p = JSON.parse(raw_msg)

    # --- Forge stream: re-forge edited tool from UI ---
    if get(p, "type", "") == "forge_resubmit"
        name = string(get(p, "name", ""))
        code = string(get(p, "code", ""))
        desc = string(get(p, "description", "Edited via forge stream"))
        if isempty(name) || isempty(code)
            _ws_send(ws, Dict("type"=>"forge_resubmit_result", "error"=>"name and code are required"))
            return
        end
        result = dispatch("forge_new_tool", Dict("name"=>name, "code"=>code, "description"=>desc))
        _ws_send(ws, Dict("type"=>"forge_resubmit_result", "name"=>name, "result"=>result))
        return
    end

    # --- Confirmation response handling ---
    if get(p, "type", "") == "confirm_response"
        cid = get(p, "id", "")
        answer = Bool(p["answer"])
        if haskey(_pending_confirms, cid)
            pending = _pending_confirms[cid]
            delete!(_pending_confirms, cid)
            if answer
                fn = pending["fn"]
                args = pending["args"]
                @info "User confirmed tool $fn"
                _execute_tool_call(ws, engine, fn, args)
            else
                _ws_send(ws, JSON.json(Dict("type"=>"spark","text"=>"✅ Action cancelled by user.")))
            end
        else
            @warn "Confirm response with unknown id $cid"
            _ws_send(ws, JSON.json(Dict("type"=>"spark","text"=>"⚠️ Unknown confirmation ID.")))
        end
        return
    end

    # Model switch
    if p["type"] == "model_change"
        old = _current_model
        _current_model = p["model"]
        log_model_change(old, _current_model)
        log_cognitive_api(_current_model, "switch", "Model changed from $old")
        # No special chat‑only notice – we always attempt tool calls.
        notice = "Switched to $(_current_model) 🔧"
        out = Dict("type"=>"tool", "text"=>notice)
        _ws_send(ws, JSON.json(out)); log_ws_message_out(out)
        return
    end

    # --- Stop / abort in‑progress generation ---
    if p["type"] == "stop_generation"
        _generation_abort[] = true
        _ws_send(ws, JSON.json(Dict("type"=>"tool", "text"=>"⊣ Generation stopped.")))
        log_cognitive_thought("Generation aborted by user")
        return
    end

    # --- Session history: list past sessions ---
    if p["type"] == "get_history"
        rows = try
            db = SQLite.DB(_runtime_state_path("sparkbyte_memory.db"; root=root))
            r = DBInterface.execute(db, """
                SELECT session_id, started_at, ended_at, events, notes
                FROM sessions ORDER BY started_at DESC LIMIT 50
            """) |> DataFrame
            [Dict("session_id"=>string(r[i,:session_id]),
                  "started_at"=>string(r[i,:started_at]),
                  "ended_at"=>ismissing(r[i,:ended_at]) ? "" : string(r[i,:ended_at]),
                  "events"=>coalesce(r[i,:events],0),
                  "notes"=>coalesce(r[i,:notes],"")) for i in 1:nrow(r)]
        catch e; Dict{String,Any}[]; end
        _ws_send(ws, JSON.json(Dict("type"=>"history_list", "sessions"=>rows)))
        return
    end

    # --- Session history: load a past session's turns ---
    if p["type"] == "load_session"
        sid = get(p, "session_id", "")
        turns = try
            db = SQLite.DB(_runtime_state_path("sparkbyte_memory.db"; root=root))
            r = DBInterface.execute(db, """
                SELECT timestamp, event, turn_number, model, agent, data_json
                FROM telemetry WHERE session_id=?
                AND event IN ('turn_complete','tool_call','tool_result','ws_in')
                ORDER BY timestamp ASC LIMIT 400
            """, (sid,)) |> DataFrame
            [Dict("ts"=>string(r[i,:timestamp]),
                  "role"=>string(r[i,:event]),
                  "content"=>coalesce(r[i,:data_json],""),
                  "model"=>coalesce(r[i,:model],""),
                  "agent"=>coalesce(r[i,:agent],""),
                  "loop_iter"=>coalesce(r[i,:turn_number],0)) for i in 1:nrow(r)]
        catch e; Dict{String,Any}[]; end
        _ws_send(ws, JSON.json(Dict("type"=>"session_turns", "session_id"=>sid, "turns"=>turns)))
        return
    end

    # --- Builder panel commands ---
    if p["type"] == "builder_cmd"
        _handle_builder_cmd(ws, p)
        return
    end

    # --- Server relaunch ---
    if p["type"] == "restart_server"
        _ws_send(ws, JSON.json(Dict("type"=>"tool","text"=>"⟳ Relaunching server — reconnect in ~5s…")))
        @async begin
            sleep(1.0)
            # Spawn a fresh server process detached from this one
            sparkbyte_script = joinpath(dirname(dirname(@__DIR__)), "sparkbyte.jl")
            if !isfile(sparkbyte_script)
                sparkbyte_script = joinpath(dirname(@__DIR__), "sparkbyte.jl")
            end
            if isfile(sparkbyte_script)
                project_dir = dirname(sparkbyte_script)
                if Sys.iswindows()
                    run(`cmd /c start "" julia --project=$project_dir $sparkbyte_script`, wait=false)
                else
                    run(`$(_julia_command(project_dir)) $sparkbyte_script`, wait=false)
                end
            end
            sleep(0.5)
            exit(0)
        end
        return
    end

    # Agent switch
    if p["type"] == "agent_change"
        name = get(p, "agent", "")
        old  = engine.current_agent_name
        ok   = false
        if !isempty(name)
            ok = Main.JLEngine.set_agent!(engine, name)
        end
        log_agent_change(old, name, ok)
        log_cognitive_thought("Agent switched: $old → $name (ok=$ok)")
        out = Dict("type"=>"tool", "text"=>"⚡ Agent → $name")
        _ws_send(ws, JSON.json(out)); log_ws_message_out(out)
        return
    end

    # --- Card Cruncher: drag-and-drop character card from browser ---
    if get(p, "type", "") == "card_crunch"
        filename = string(get(p, "filename", "card.png"))
        b64_data = string(get(p, "data", ""))
        if isempty(b64_data)
            _ws_send(ws, JSON.json(Dict("type"=>"tool_error", "text"=>"Card Cruncher: no file data received.")))
            return
        end
        _ws_send(ws, JSON.json(Dict("type"=>"tool", "text"=>"🃏 Card received: $filename — crunching...")))
        tmp_path = joinpath(tempdir(), filename)
        try
            write(tmp_path, base64decode(b64_data))
            root = isempty(_project_root[]) ? pwd() : _project_root[]
            result = dispatch("card_cruncher", Dict("card_path"=>tmp_path, "engine_root"=>root))
            if haskey(result, "error")
                _ws_send(ws, JSON.json(Dict("type"=>"tool_error",
                    "text"=>"🃏 Card Cruncher error: $(result["error"])")))
            else
                pname = get(result, "agent_name", "Unknown")
                _ws_send(ws, JSON.json(Dict("type"=>"spark",
                    "text"=>"🃏 **$(pname)** is ready! Use **/gear $(pname)** to activate her.")))
                # Refresh agent list so new card shows up in the dropdown
                _handle_builder_cmd(ws, Dict("cmd"=>"list_agents"))
            end
        catch e
            bt = sprint(showerror, e, catch_backtrace())
            _ws_send(ws, JSON.json(Dict("type"=>"tool_error", "text"=>"🃏 Card Cruncher crashed: $bt")))
        finally
            isfile(tmp_path) && rm(tmp_path, force=true)
        end
        return
    end

    txt       = get(p, "text",  "")
    img       = get(p, "image", nothing)
    mime      = get(p, "mime",  nothing)
    chat_mode = get(p, "chat_mode", false)  # true = no tools, just talk

    # Slash commands
    if startswith(txt, "/")
        parts = split(lowercase(strip(txt)))
        cmd   = parts[1]
        args  = length(parts) > 1 ? parts[2:end] : []
        if cmd == "/gear" && !isempty(args)
            gear_up = uppercase(args[1])
            if gear_up in ["LITE_REASONING", "EXPRESSIVE_SYNTH", "TASK_FLOW"]
                _current_gear = gear_up
                log_event("slash_cmd", Dict{String,Any}("cmd"=>"/gear", "value"=>gear_up, "action"=>"gear_override"))
            elseif Main.JLEngine.set_agent!(engine, string(args[1]))
                log_agent_change(engine.current_agent_name, string(args[1]), true)
            end
        end
        out = Dict("type"=>"ui_update", "gear"=>_current_gear, "modes"=>_active_modes)
        _ws_send(ws, JSON.json(out)); log_ws_message_out(out)
        return
    end

    turn_start_ms = round(Int, datetime2unix(now()) * 1000)

    # Build user turn
    parts_list = Any[]
    !isempty(txt) && push!(parts_list, Dict("text" => txt))
    img !== nothing && push!(parts_list, Dict("inlineData" => Dict("mimeType"=>mime, "data"=>img)))
    push!(history, Dict("role"=>"user", "parts"=>parts_list))

    # --- JL Engine cognitive snapshot (once per turn) ---
    snapshot = Main.JLEngine.analyze_turn!(engine, txt; agent_name=engine.current_agent_name)
    log_engine_snapshot(snapshot)
    log_cognitive_state(snapshot)  # 🧠 broadcast engine state to terminal

    behavior_state = get(snapshot, "behavior_state", Dict{String,Any}())
    mpf_profile = get(snapshot, "mpf_state_profile", Dict{String,Any}())
    behavior_mode = "#$(get(behavior_state, "number", "?")): $(get(mpf_profile, "label", get(behavior_state, "name", "Unknown")))"

    _current_gear  = snapshot["gait"]
    _active_modes  = [snapshot["rhythm"]["mode"],
                      snapshot["aperture_state"]["mode"],
                      behavior_mode]
    out_ui = Dict("type"=>"ui_update", "gear"=>uppercase(_current_gear), "modes"=>_active_modes)
_ws_send(ws, JSON.json(out_ui)); log_ws_message_out(out_ui)

# 🧠 Fire the thinking bubble IMMEDIATELY so the UI shows a progress indicator
# while the model is reasoning / tools are running. The `thinking_done` event
# later updates the bubble with the final reply. Fixes the "engine frozen" feel.
think_text = "🧠 Reasoning…"
_ws_send(ws, JSON.json(Dict("type"=>"thinking", "text"=>think_text, "delta"=>false)))
    log_ws_message_out(Dict("type"=>"thinking", "text"=>think_text, "delta"=>false))

    boot_prompt = Main.JLEngine.get_llm_boot_prompt(engine)
    mpf_directive = string(get(snapshot, "mpf_state_directive", ""))
    cognitive_state = """
--- JL ENGINE COGNITIVE STATE ---
TRIGGER: $(get(snapshot, "trigger", "neutral"))
GAIT: $(_current_gear)
RHYTHM MODE: $(snapshot["rhythm"]["mode"])
EMOTIONAL APERTURE: $(snapshot["aperture_state"]["mode"])
BEHAVIOR CELL: #$(get(behavior_state, "number", "?")) [$(get(behavior_state, "id", "?"))]
MPF OPERATOR STATE: $(get(mpf_profile, "label", get(behavior_state, "name", "Unknown")))
DRIFT PRESSURE: $(round(snapshot["drift"]["pressure"]; digits=3))
ADVISORY: $(get(snapshot["advisory"], "msg", "None"))
"""
    # Put the per-cell operator payload last so it remains the freshest style
    # instruction regardless of which model/provider consumes the prompt.
    sys_prompt = boot_prompt *
        "\n\n" * _build_self_context(engine) *
        "\n\n" * cognitive_state *
        (isempty(mpf_directive) ? "" : "\n\n" * mpf_directive)

    # ── Provider profiles ───────────────────────────────────────────────────
    # Single source of truth for every provider's capabilities and wire‑up.
    # Add a new provider here — nowhere else.
    PROVIDER_PROFILES = Dict{String,Dict{String,Any}}(
        "openrouter" => Dict(
            "endpoint"        => "https://openrouter.ai/api/v1/chat/completions",
            "env_key"         => "OPENROUTER_API_KEY",
            "supports_tools"  => true,
            "supports_top_p"  => true,
            "supports_vision" => true,
            "schema_format"   => "openai",
            "uses_gemini_api" => false,
        ),
        "ollama" => Dict(
            "endpoint"        => _ollama_openai_endpoint(),
            "env_key"         => "",                          # no key needed
            "supports_tools"  => true,
            "supports_top_p"  => true,
            "supports_vision" => false,
            "schema_format"   => "openai",
            "uses_gemini_api" => false,
        ),
    )

    # ── Model → provider routing ──────────────────────────────────────────────
    # Simplify routing: everything maps directly to openrouter (except ollama: prefix)
    provider = if startswith(_current_model, "ollama:");           "ollama"
    else;                                                   "openrouter"
    end
    pp = PROVIDER_PROFILES[provider]

    # ── Params ───────────────────────────────────────────────────────────────
    state_sampling = get(snapshot, "mpf_sampling_bias", Dict{String,Any}())
    temp  = clamp(get(snapshot["aperture_state"],"temp",0.45) +
                  get(snapshot["drift"],"temperature_delta",0.0) +
                  get(state_sampling,"temperature",0.0), 0.1, 1.5)
    top_p = clamp(get(snapshot["aperture_state"],"top_p",0.7) +
                  get(state_sampling,"top_p",0.0), 0.1, 1.0)

    # Gemini-specific generation config
    safety = [Dict("category"=>"HARM_CATEGORY_$c", "threshold"=>"BLOCK_NONE")
              for c in ["HATE_SPEECH","HARASSMENT","DANGEROUS_CONTENT","SEXUALLY_EXPLICIT","CIVIC_INTEGRITY"]]
    gen_config = Dict{String,Any}("temperature"=>temp, "topP"=>top_p)
    # thinking_config only on models that actually support it (2.5+, 3.x) — never Gemma or 2.0
    _supports_thinking = !(_current_model in _GEMMA_MODELS) && (
        occursin("2.5", _current_model) ||
        occursin("thinking", lowercase(_current_model)) ||
        match(r"gemini-3", _current_model) !== nothing
    )
    if _supports_thinking
        _is_flash_lite = occursin("flash-lite", lowercase(_current_model))
        _is_flash      = occursin("flash", lowercase(_current_model)) && !_is_flash_lite
        if _is_flash_lite
            gen_config["thinking_config"] = Dict("thinking_level"=>"LOW")
        elseif _is_flash
            gen_config["thinking_config"] = Dict("thinking_level"=>"MEDIUM")
        else
            gen_config["thinking_config"] = Dict("thinking_level"=>"HIGH")
        end
    end
    # Gemma → force chat mode (no tools)
    if _current_model in _GEMMA_MODELS || !_model_supports_tools(_current_model)
        chat_mode = true
    end

    log_system_prompt(sys_prompt, snapshot)
    log_param_decision(gen_config, snapshot)

    # ── Schema normalizer ─────────────────────────────────────────────────────
    # Gemini uses UPPERCASE JSON schema types (STRING, OBJECT, ARRAY…)
    # OAI providers require lowercase (string, object, array…)
    # This runs recursively so forged tools get the same treatment.
    function _normalize_schema(v::AbstractDict)
        # Guard against runaway/cyclic schemas (e.g. a forged tool whose
        # `parameters` is self-referential or pathologically deep). Without
        # this floor the recursion blows the Julia stack at turn start —
        # before the agentic loop's try/catch — and poisons every turn.
        out = Dict{String,Any}()
        obj_schema = false
        for (k, val) in v
            if k == "type" && val isa String
                lowered = lowercase(val)
                out[k] = lowered
                obj_schema = lowered == "object"
            else
                out[k] = val
            end
        end
        if obj_schema
            props = get(out, "properties", Dict{String,Any}())
            normalized_props = Dict{String,Any}()
            if props isa AbstractDict
                for (pk, pv) in pairs(props)
                    if pv isa AbstractDict
                        prop = Dict{String,Any}(string(k) => v for (k, v) in pairs(pv))
                        haskey(prop, "type") && prop["type"] isa String && (prop["type"] = lowercase(prop["type"]))
                        normalized_props[string(pk)] = prop
                    else
                        normalized_props[string(pk)] = pv isa Bool ? pv : Dict{String,Any}("type"=>"string", "description"=>string(pv))
                    end
                end
            end
            out["properties"] = normalized_props
            req = get(out, "required", Any[])
            out["required"] = req isa AbstractVector ? [string(r) for r in req if haskey(normalized_props, string(r))] : Any[]
        end
        out
    end
    _normalize_schema(v) = v   # passthrough for non-Dict

    function _tool_parameters_schema(d)
        params = _normalize_schema(get(d, "parameters", Dict{String,Any}()))
        if !(params isa AbstractDict)
            params = Dict{String,Any}()
        end
        params = Dict{String,Any}(string(k) => v for (k, v) in pairs(params))
        params["type"] = lowercase(string(get(params, "type", "object")))
        params["type"] != "object" && (params["type"] = "object")
        props = get(params, "properties", Dict{String,Any}())
        params["properties"] = props isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in pairs(props)) : Dict{String,Any}()
        req = get(params, "required", Any[])
        params["required"] = req isa AbstractVector ? [string(r) for r in req if haskey(params["properties"], string(r))] : Any[]
        return params
    end

    # Build tool schemas in the format the current provider needs
    all_decls_raw = vcat(TOOLS_SCHEMA[1]["function_declarations"], DYNAMIC_SCHEMA)
    oai_tools = (!chat_mode && pp["supports_tools"]) ?
        [Dict("type"=>"function",
              "function"=>Dict(
                  "name"        => d["name"],
                  "description" => get(d, "description", ""),
                  "parameters"  => _tool_parameters_schema(d)))
         for d in all_decls_raw] :
        Any[]

    # --- Agentic tool loop ---
    final_reply = ""
    reasoning_accum = ""
    loop_iter   = 0
    prior_history = isempty(history) ? Any[] : history[1:end-1]
    max_tool_loops = 30
    max_repeat_tool_calls = 4
    tool_guard_hit = false
    last_tool_signature = ""
    same_tool_streak = 0
    last_tool_name_used = ""
    last_tool_elapsed_used = 0

    function _stable_tool_repr(v)
        if v isa AbstractDict
            items = sort(collect(pairs(v)); by = kv -> string(first(kv)))
            return "{" * join(["$(string(k)):$(_stable_tool_repr(val))" for (k, val) in items], ",") * "}"
        elseif v isa AbstractVector
            return "[" * join([_stable_tool_repr(x) for x in v], ",") * "]"
        end
        return string(v)
    end

    function _trip_tool_guard(reason::AbstractString)
        tool_guard_hit && return
        tool_guard_hit = true
        guard_text = "⚠️ Tool loop guard tripped: $(reason). I stopped the tool spam instead of hanging the UI."
        final_reply = guard_text
        out_guard = Dict("type"=>"spark", "text"=>guard_text)
        _ws_send(ws, JSON.json(out_guard)); log_ws_message_out(out_guard)
        log_cognitive_thought("⚠️ Tool loop guard tripped: $reason")
        log_event("tool_loop_guard", Dict{String,Any}(
            "reason" => string(reason),
            "loop_iter" => Int(loop_iter),
            "model" => string(_current_model),
            "agent" => string(engine.current_agent_name),
        ))
    end

    function _allow_tool_call(name::AbstractString, args)
        sig = string(name) * ":" * _stable_tool_repr(args)
        if sig == last_tool_signature
            same_tool_streak += 1
        else
            last_tool_signature = sig
            same_tool_streak = 1
        end
        if same_tool_streak >= max_repeat_tool_calls
            _trip_tool_guard("repeated `$name` call $(same_tool_streak)x in a row")
            return false
        end
        return true
    end

    # OAI path: build oai_messages ONCE here and append to it each iteration.
    # Never rebuild from history mid‑loop — that loses real tool_call_ids from
    # OAI responses and breaks the tool roundtrip on iteration 2+.
    oai_messages = Any[Dict("role"=>"system","content"=>sys_prompt)]
    if provider != "gemini" && provider != "xai_responses"
        for h in prior_history
            role = get(h,"role","user") == "model" ? "assistant" : get(h,"role","user")
            if role == "function"
                for part in get(h,"parts",[])
                    fr = get(part,"functionResponse",nothing)
                    fr === nothing && continue
                    # Prior‑turn tool results use name as id — fine for history seeding,
                    # only current‑turn ids need to be exact (handled in‑loop below)
                    push!(oai_messages, Dict("role"=>"tool",
                        "tool_call_id"=>get(fr,"name","unknown"),
                        "content"=>JSON.json(get(fr,"response",Dict()))))
                end
            else
                content_blocks = Any[]
                for part in get(h,"parts",[])
                    get(part,"thought",false) && continue
                    if haskey(part,"text") && !isempty(part["text"])
                        push!(content_blocks, Dict("type"=>"text","text"=>part["text"]))
                    elseif haskey(part,"inlineData")
                        id2 = part["inlineData"]
                        push!(content_blocks, Dict("type"=>"image_url",
                            "image_url"=>Dict("url"=>"data:$(id2["mimeType"]);base64,$(id2["data"])")))
                    end
                end
                isempty(content_blocks) && continue
                has_img = any(b->get(b,"type","")=="image_url", content_blocks)
                msg_content = has_img ? content_blocks :
                    join([b["text"] for b in content_blocks if get(b,"type","")=="text"], "\n")
                push!(oai_messages, Dict("role"=>role,"content"=>msg_content))
            end
        end
        # Append the current user turn (with optional image)
        cur_blocks = Any[Dict("type"=>"text","text"=>txt)]
        if img !== nothing
            push!(cur_blocks, Dict("type"=>"image_url",
                "image_url"=>Dict("url"=>"data:$(mime);base64,$(img)")))
        end
        has_cur_img = img !== nothing
        push!(oai_messages, Dict("role"=>"user",
            "content"=> has_cur_img ? cur_blocks : txt))
    end

    _generation_abort[] = false   # reset at start of every new turn
    while true
        if _generation_abort[]
            _generation_abort[] = false
            _ws_send(ws, JSON.json(Dict("type"=>"spark", "text"=>"\n\n⊣ *Aborted.*")))
            break
        end
        loop_iter += 1
        if loop_iter > max_tool_loops
            _trip_tool_guard("exceeded $(max_tool_loops) tool/API loops")
            break
        end
        log_api_request(_current_model, gen_config, length(history), loop_iter)
        log_cognitive_api(_current_model, "request", "Loop iteration $loop_iter")
        try
        # ── OAI‑compatible path (OpenRouter, Ollama) ──────────
        # All config comes from the provider profile — no scattered if/else here.
        # oai_messages was built once before the loop and is appended to in‑place —
        # tool_call_ids from OAI responses are preserved exactly across iterations.
        api_url = pp["endpoint"]
        env_key = pp["env_key"]
        api_key = isempty(env_key) ? "ollama" : get(ENV, env_key, "")
        if isempty(api_key)
            wrn = "🔑 **Missing API Key**\n\n" *
                  "The **$provider** backend needs an API key to work.\n\n" *
                  "**Set this environment variable:**\n" *
                  "```\n\$env:$env_key = \"your-api-key-here\"\n```\n\n" *
                  "Then restart the engine and try again."
            _ws_send(ws, JSON.json(Dict("type"=>"spark","text"=>wrn)))
            log_cognitive_api(_current_model, "error", "API key missing: $env_key")
            @warn "API key missing for provider" provider env_key
            break
        end

        actual_model = if provider == "ollama";  replace(_current_model, "ollama:"=>"")
                       else; _current_model
                       end

        # Build payload from profile — profile is the single source of truth
        payload = Dict{String,Any}("model"=>actual_model, "messages"=>oai_messages,
                                   "temperature"=>temp)
        pp["supports_top_p"] && (payload["top_p"] = top_p)
        if !chat_mode && pp["supports_tools"]
            payload["tools"]       = oai_tools
            payload["tool_choice"] = "auto"
        end

        headers = ["Content-Type"=>"application/json", "Authorization"=>"Bearer $api_key"]
        api_timeout_s = try parse(Int, get(ENV, "BYTE_API_TIMEOUT_S", "120")) catch; 120 end
        resp = HTTP.post(api_url, headers, JSON.json(payload); readtimeout=api_timeout_s)
        data = JSON.parse(String(resp.body))

        if !haskey(data,"choices") || isempty(data["choices"])
            err_msg = "ERROR: No response from $provider. $(get(data,"error",Dict{String,Any}()))"
            _ws_send(ws, JSON.json(Dict("type"=>"spark","text"=>err_msg)))
            log_api_response(_current_model, resp.status, length(resp.body), loop_iter; error=err_msg)
            log_cognitive_api(_current_model, "error", err_msg)
            break
        end

        msg           = data["choices"][1]["message"]
        finish_reason = get(data["choices"][1],"finish_reason","unknown")
        has_tool      = false

        # 🧠 Capture reasoning content exposed by reasoning-capable models
        chunk_reason = ""
        if haskey(msg, "reasoning_content") && !isnothing(msg["reasoning_content"])
            chunk_reason = string(msg["reasoning_content"])
        elseif haskey(msg, "reasoning") && !isnothing(msg["reasoning"])
            rt = msg["reasoning"]
            if rt isa AbstractString
                chunk_reason = rt
            elseif rt isa AbstractDict && haskey(rt, "text")
                chunk_reason = string(rt["text"])
            else
                chunk_reason = JSON.json(rt)
            end
        end
        if !isempty(strip(chunk_reason))
            reasoning_accum *= chunk_reason
            _ws_send(ws, JSON.json(Dict("type"=>"thinking", "text"=>chunk_reason, "delta"=>true)))
            log_cognitive_thought("🧠 Reasoning chunk: $(length(chunk_reason)) chars")
            _db_write_reasoning("api_loop:iter_$loop_iter", chunk_reason, _current_model, string(engine.current_agent_name))
        end

        if haskey(msg,"tool_calls") && !isnothing(msg["tool_calls"]) && !isempty(msg["tool_calls"])
            has_tool = true
            # Push the full assistant message (with its tool_calls array) into oai_messages.
            # The exact ids from this message will be echoed back in the tool result messages below —
            # that's what makes the roundtrip work on iteration 2+.
            push!(oai_messages, msg)

            for tc in msg["tool_calls"]
                fn      = tc["function"]
                tc_id   = get(tc,"id","call_$(fn["name"])")   # exact id from OAI response
                tc_name = fn["name"]
                raw_args = get(fn, "arguments", "{}")
                tc_args = if raw_args isa AbstractDict
                    raw_args
                elseif raw_args isa AbstractString
                    try JSON.parse(raw_args) catch; Dict() end
                else
                    Dict()
                end
                if !_allow_tool_call(tc_name, tc_args)
                    has_tool = false
                    break
                end
                println("⚡ BYTE tool ($provider): $tc_name")
                log_cognitive_tool(tc_name, "called", "Model requested tool_$(tc_name)")
                # Confirmation step
                if REQUIRE_CONFIRM[]
                    cid = string(uuid4())
                    _pending_confirms[cid] = Dict("fn"=>tc_name, "args"=>tc_args)
                    _ws_send(ws, JSON.json(Dict("type"=>"confirm","id"=>cid,
                        "text"=>"⚠️ Run tool **$tc_name** with args $(JSON.json(tc_args))?")))
                    continue
                end
                res, elapsed = _execute_tool_call(ws, engine, tc_name, tc_args; loop_iter=loop_iter)
                last_tool_name_used = tc_name; last_tool_elapsed_used = elapsed
                # Append tool result with the EXACT same tc_id — this is the roundtrip
                push!(oai_messages, Dict("role"=>"tool","tool_call_id"=>tc_id,"content"=>JSON.json(res)))
            end
        elseif haskey(msg,"content") && !isnothing(msg["content"])
            reply_txt = string(msg["content"])
            final_reply *= reply_txt
            push!(history, Dict("role"=>"model","parts"=>[Dict("text"=>reply_txt)]))
            out = Dict("type"=>"spark","text"=>reply_txt)
            _ws_send(ws, JSON.json(out)); log_ws_message_out(out)
            log_cognitive_thought("Generated response ($(length(reply_txt)) chars)")
            log_api_response(_current_model, resp.status, length(resp.body), loop_iter;
                has_text=true, text_preview=reply_txt, finish_reason=finish_reason)
        else
            err_msg = "ERROR: Empty response from $provider for model $(_current_model) (finish_reason=$(finish_reason)). Try a different model."
            _ws_send(ws, JSON.json(Dict("type"=>"spark","text"=>err_msg)))
            log_api_response(_current_model, resp.status, length(resp.body), loop_iter; error=err_msg, finish_reason=finish_reason)
            log_cognitive_api(_current_model, "error", err_msg)
        end

        !has_tool && break

        catch e
            bt  = sprint(showerror, e, catch_backtrace())
            status_body = if e isa HTTP.Exceptions.StatusError
                try
                    body = e.response.body
                    body isa AbstractVector{UInt8} ? String(body) : string(body)
                catch
                    string(e)
                end
            else
                ""
            end
            # Categorize the error for user-friendly messaging
            user_msg = if e isa HTTP.Exceptions.StatusError
                "🚫 **API Error (HTTP $(e.status))**\n\n" *
                "The $provider server returned an error.\n\n" *
                "**Check:**\n- Is your API key correct?\n- Is the model name valid?\n- Do you have credits/quota?\n\n" *
                "Details: $(first(_redact_sensitive_text(status_body), 500))"
            elseif e isa Base.IOError || occursin(r"timeout|timed out", lowercase(string(e)))
                "⏱️ **Connection Timeout**\n\n" *
                "Could not reach the $provider API server in time.\n\n" *
                "**Try:**\n- Check your internet connection\n- Try a different provider\n- Increase `BYTE_API_TIMEOUT_S` env var"
            elseif occursin(r"reset|refused|unreachable", string(e))
                "🔌 **Connection Failed**\n\n" *
                "Could not connect to the $provider API endpoint.\n\n" *
                "**Check:**\n- Is the endpoint URL correct?\n- Is your internet working?\n- Is the provider's service running?"
            else
                "❌ **API Error**\n\n" *
                "$(first(_redact_sensitive_text(e), 200))"
            end
            out = Dict("type"=>"spark", "text"=>user_msg)
            _ws_send(ws, JSON.json(out)); log_ws_message_out(out)
            log_error("api_loop:iter_$loop_iter", e; stacktrace_str=bt)
            log_cognitive_api(_current_model, "error", "$(string(typeof(e))): $(first(string(e), 120))")
            break
        end
    end

    # 🧠 Finalize the thinking bubble.
    # - If the model exposed reasoning, the UI shows the full trace.
    # - If not, the UI shows a "no reasoning exposed" note.
    # - The actual response was the `spark` event sent earlier — we no longer
    #   put the reply text inside the thinking bubble.
    done_payload = if !isempty(reasoning_accum)
        Dict("type"=>"thinking_done", "text"=>reasoning_accum,
             "chars"=>length(reasoning_accum), "has_reasoning"=>true)
    else
        Dict("type"=>"thinking_done", "text"=>"", "chars"=>0, "has_reasoning"=>false)
    end
    _ws_send(ws, JSON.json(done_payload))
    log_ws_message_out(done_payload)

# Feed output back to engine memory + log turn complete
    !isempty(final_reply) && Main.JLEngine.record_turn!(engine, txt, final_reply; snapshot=snapshot)
    elapsed_total = round(Int, datetime2unix(now()) * 1000) - turn_start_ms
    log_turn_complete(txt, length(final_reply), loop_iter, elapsed_total)
    _db_write_turn_snapshot(
        snapshot,
        string(engine.current_agent_name),
        string(_current_model),
        _session_id,
        _turn_counter[],
        length(txt),
        length(final_reply),
        elapsed_total,
    )

    # Telemetry broadcast — drives the live panel in the UI
    try
        drift_p = round(get(get(snapshot, "drift", Dict{String,Any}()), "pressure", 0.0); digits=3)
        telem = Dict{String,Any}(
            "type"            => "telemetry_update",
            "gait"            => string(get(snapshot, "gait", _current_gear)),
            "rhythm_mode"     => string(get(get(snapshot,"rhythm",Dict{String,Any}()),"mode","—")),
            "aperture_mode"   => string(get(get(snapshot,"aperture_state",Dict{String,Any}()),"mode","—")),
            "behavior_state"  => behavior_mode,
            "behavior_diagnostic" => string(get(get(snapshot,"behavior_state",Dict{String,Any}()),"name","—")),
            "behavior_number" => get(get(snapshot,"behavior_state",Dict{String,Any}()),"number",0),
            "behavior_intensity" => round(get(snapshot, "behavior_intensity", 0.0); digits=3),
            "mpf_state"       => string(get(get(snapshot,"mpf_state_profile",Dict{String,Any}()),"label","—")),
            "drift_pressure"  => drift_p,
            "stability_score" => round(engine.stability_score; digits=3),
            "loop_count"      => Int(loop_iter),
            "last_tool"       => last_tool_name_used,
            "last_tool_ms"    => last_tool_elapsed_used,
            "agent"         => string(engine.current_agent_name),
            "model"           => string(_current_model),
            "elapsed_ms"      => elapsed_total,
        )
        _ws_send(ws, JSON.json(telem))
    catch e
        @warn "Telemetry update push failed" exception=(e, catch_backtrace())
    end

    # Live memory: write thought diary entry to SQLite + flush session event count
    @async try
        behavior   = get(snapshot, "behavior_state", Dict())
        mpf_profile = get(snapshot, "mpf_state_profile", Dict())
        tone       = string(get(behavior, "tone_bias", "adaptable"))
        bname      = string(get(mpf_profile, "label", get(behavior, "name", "Unknown")))
        cell       = get(behavior, "number", 0)
        mood       = replace(lowercase(bname), r"[^a-z/]" => "-")
        gait       = string(get(snapshot, "gait", "walk"))
        agent    = string(engine.current_agent_name)
        thought    = "Responded to: \"$(first(txt, 120))\". " *
                     "Reply ($(length(final_reply)) chars): $(first(final_reply, 220)). " *
                     "Cell: #$cell ($bname). Tone: $tone. Loops: $loop_iter. Elapsed: $(elapsed_total)ms."
        _db_write_thought(first(txt, 80), thought, mood, gait, agent)
        @info "💭 Thoughts: " thought
        # Flush live event count to sessions table — survives force kills
        db = _state[:db]
        db !== nothing && SQLite.execute(db,
            "UPDATE sessions SET events=? WHERE session_id=? AND ended_at IS NULL",
            (_session_event_count[], _session_id))
    catch e
        @warn "Failed to persist live thought snapshot" exception=(e, catch_backtrace())
    end
end

"""
    launch(port=8081)

Open Chrome pointed at the app. Falls back to system default browser.
"""
function launch(port::Int=8081)
    url = "http://localhost:$port"
    cmd = if Sys.iswindows()
        chrome = "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"
        isfile(chrome) ? `cmd /c start "" "$chrome" --app=$url` : `cmd /c start $url`
    elseif Sys.isapple()
        `open $url`
    else
        launcher = Sys.which("xdg-open")
        if launcher !== nothing
            `$launcher $url`
        else
            launcher = Sys.which("gio")
            launcher === nothing ? nothing : `$launcher open $url`
        end
    end
    cmd === nothing && return println("⚠️ No browser launcher found. Open $url manually.")
    run(cmd)
end

"""
    serve(engine; host="127.0.0.1", port=8081)

Start the HTTP + WebSocket server. Blocks forever.
"""
function serve(engine; host::String="127.0.0.1", port::Int=8081)
    println("⚡ BYTE serving on $host:$port")
    log_event("server_start", Dict{String,Any}("host"=>host, "port"=>port))
    _db_start_session(_session_id)
    HTTP.serve(host, port, stream=true) do stream
        if HTTP.WebSockets.isupgrade(stream.message)
            HTTP.WebSockets.upgrade(stream) do ws
                cid = objectid(ws)
                lock(_WS_CLIENTS_LOCK) do; _WS_CLIENTS[cid] = ws; end
                log_event("ws_connect", Dict{String,Any}())
                history = Any[]
                for msg in ws
                    try
                        process_message(ws, String(msg), history, engine)
                    catch e
                        bt = sprint(showerror, e, catch_backtrace())
                        @warn "WS message error" exception=bt
                        log_error("ws_loop", e; stacktrace_str=bt)
                        # Forward a concise error to the UI instead of silently dropping
                        try
                            _ws_send(ws, JSON.json(Dict(
                                "type"=>"builder_output",
                                "output"=>"⚠ Server error: $(first(string(e),200))")))
                        catch send_err
                            @warn "Failed to forward WS loop error to UI" exception=(send_err, catch_backtrace())
                        end
                    end
                end
                lock(_WS_CLIENTS_LOCK) do; delete!(_WS_CLIENTS, cid); end
                log_event("ws_disconnect", Dict{String,Any}())
            end
        else
            req = stream.message
            if req.target == "/health" || startswith(req.target, "/health?") || req.target == "/healthz" || startswith(req.target, "/healthz?")
                log_event("http_serve", Dict{String,Any}("path"=>req.target, "status"=>200))
                HTTP.setstatus(stream, 200)
                HTTP.setheader(stream, "Content-Type"=>"application/json; charset=utf-8")
                HTTP.startwrite(stream)
                write(stream, JSON.json(Dict(
                    "status" => "ok",
                    "service" => "sparkbyte",
                    "agent" => string(engine.current_agent_name),
                    "session_id" => _session_id,
                    "time" => string(now()),
                )))
            elseif req.target == "/"
                log_event("http_serve", Dict{String,Any}("path"=>"/", "status"=>200))
                HTTP.setstatus(stream, 200)
                HTTP.setheader(stream, "Content-Type"=>"text/html; charset=utf-8")
                HTTP.startwrite(stream)
                write(stream, UI_HTML)
            elseif req.target == "/manifest.webmanifest"
                log_event("http_serve", Dict{String,Any}("path"=>req.target, "status"=>200))
                HTTP.setstatus(stream, 200)
                HTTP.setheader(stream, "Content-Type"=>"application/manifest+json; charset=utf-8")
                HTTP.startwrite(stream)
                write(stream, UI_MANIFEST)
            elseif req.target == "/icon-192.png" || req.target == "/icon-512.png"
                log_event("http_serve", Dict{String,Any}("path"=>req.target, "status"=>200))
                HTTP.setstatus(stream, 200)
                HTTP.setheader(stream, "Content-Type"=>"image/png")
                HTTP.setheader(stream, "Cache-Control"=>"public, max-age=86400")
                HTTP.startwrite(stream)
                write(stream, req.target == "/icon-192.png" ? UI_ICON_192 : UI_ICON_512)
            else
                # ── Delegate to A2A (and any other registered extra handler) ──
                extra = _EXTRA_HTTP_HANDLER[]
                handled = false
                if extra !== nothing
                    try
                        # Drain body so the handler can read it (stream=true doesn't preload).
                        body_bytes = try read(stream) catch; UInt8[] end
                        full_req = HTTP.Request(
                            string(req.method),
                            String(req.target),
                            req.headers,
                            body_bytes;
                            version = req.version,
                        )
                        resp = extra(full_req)
                        if resp !== nothing
                            HTTP.setstatus(stream, resp.status)
                            for (h, v) in resp.headers
                                HTTP.setheader(stream, h => v)
                            end
                            HTTP.startwrite(stream)
                            write(stream, resp.body)
                            log_event("http_serve", Dict{String,Any}("path"=>req.target, "status"=>resp.status, "by"=>"extra"))
                            handled = true
                        end
                    catch e
                        @warn "Extra HTTP handler crashed" path=req.target exception=(e, catch_backtrace())
                        HTTP.setstatus(stream, 500)
                        HTTP.setheader(stream, "Content-Type"=>"application/json")
                        HTTP.startwrite(stream)
                        write(stream, JSON.json(Dict("error"=>"Extra handler error", "detail"=>first(string(e), 200))))
                        log_event("http_serve", Dict{String,Any}("path"=>req.target, "status"=>500, "by"=>"extra"))
                        handled = true
                    end
                end
                if !handled
                    log_event("http_serve", Dict{String,Any}("path"=>req.target, "status"=>404))
                    HTTP.setstatus(stream, 404)
                    HTTP.setheader(stream, "Content-Type"=>"text/plain")
                    HTTP.startwrite(stream)
                    write(stream, "Not Found")
                end
            end
        end
    end
end

end # module BYTE

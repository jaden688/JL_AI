# ─────────────────────────────────────────────────────────────────────────────
#  MCPClient — pure-Julia Model Context Protocol *client*
#
#  Lets the engine consume EXTERNAL MCP servers (Gmail, Slack, Notion, GitHub,
#  Postgres, and the rest of the ecosystem) as native tools. Each external tool
#  is registered into the same TOOL_MAP + DYNAMIC_SCHEMA the agent already uses,
#  so from the model's point of view an MCP-provided tool is indistinguishable
#  from a built-in one.
#
#  Transport: JSON-RPC 2.0 over stdio (newline-delimited), the transport every
#  local MCP server speaks. No Python, no pip, no conda — this is the whole
#  reason the client is pure Julia: it ships inside the compiled binary and has
#  zero external provisioning to fail.
#
#  Everything here degrades gracefully. A connector that won't spawn, won't
#  handshake, or throws mid-call is logged and skipped — it never takes the
#  engine down with it.
#
#  Included into module BYTE *after* Tools.jl, so TOOL_MAP / DYNAMIC_SCHEMA
#  already exist when register_mcp_connectors! runs.
# ─────────────────────────────────────────────────────────────────────────────

const MCP_PROTOCOL_VERSION = "2024-11-05"

# A live connection to one external MCP server.
mutable struct MCPConn
    name::String                 # logical connector name, e.g. "gmail"
    proc::Base.Process           # the spawned server process (write .in, read .out)
    next_id::Int                 # JSON-RPC request id counter
    tools::Vector{Dict{String,Any}}  # tool descriptors as returned by the server
end

# All live connections, keyed by connector name. Also used for shutdown.
const MCP_CONNS = Dict{String, MCPConn}()

# ── Low-level JSON-RPC over stdio ────────────────────────────────────────────

# Spawn the server process with bidirectional stdio. Isolated in one function
# because subprocess pipe handling is the single most platform-sensitive part;
# if a shakeout run on Windows needs a tweak, it lives here and nowhere else.
# `open(cmd, "r+")` returns a Base.Process: write its stdin via `.in`, read its
# stdout via `.out`. stderr stays attached to ours for visibility.
_mcp_spawn(cmd::Base.Cmd)::Base.Process = open(cmd, "r+")

function _mcp_send(conn::MCPConn, obj::AbstractDict)
    line = JSON.json(obj)
    write(conn.proc.in, line)
    write(conn.proc.in, "\n")
    flush(conn.proc.in)
    return nothing
end

# Issue a request and block until the response with the matching id arrives.
# Server-initiated notifications / unrelated messages are drained and ignored.
function _mcp_request(conn::MCPConn, method::String, params=nothing; timeout_s::Real=30)
    id = (conn.next_id += 1)
    req = Dict{String,Any}("jsonrpc" => "2.0", "id" => id, "method" => method)
    params !== nothing && (req["params"] = params)
    _mcp_send(conn, req)

    deadline = time() + timeout_s
    while time() < deadline
        eof(conn.proc.out) && error("MCP server '$(conn.name)' closed the connection")
        line = readline(conn.proc.out)
        isempty(strip(line)) && continue
        msg = try
            JSON.parse(line)
        catch
            continue  # not a JSON-RPC line (some servers chatter on stdout)
        end
        # Match our id. Notifications have no "id"; other responses aren't ours.
        if get(msg, "id", nothing) == id
            haskey(msg, "error") && error("MCP '$(conn.name)' $method error: $(msg["error"])")
            return get(msg, "result", Dict{String,Any}())
        end
    end
    error("MCP server '$(conn.name)' timed out on $method")
end

function _mcp_notify(conn::MCPConn, method::String, params=nothing)
    note = Dict{String,Any}("jsonrpc" => "2.0", "method" => method)
    params !== nothing && (note["params"] = params)
    _mcp_send(conn, note)
end

# ── Handshake + capabilities ─────────────────────────────────────────────────

function mcp_connect_stdio(name::String, cmd::Base.Cmd)::MCPConn
    proc = _mcp_spawn(cmd)
    conn = MCPConn(name, proc, 0, Dict{String,Any}[])

    _mcp_request(conn, "initialize", Dict{String,Any}(
        "protocolVersion" => MCP_PROTOCOL_VERSION,
        "capabilities"    => Dict{String,Any}(),
        "clientInfo"      => Dict{String,Any}("name" => "jl-engine", "version" => "0.1.0"),
    ))
    _mcp_notify(conn, "notifications/initialized")

    result = _mcp_request(conn, "tools/list")
    tools  = get(result, "tools", Any[])
    conn.tools = [Dict{String,Any}(string(k) => v for (k, v) in pairs(t)) for t in tools]
    return conn
end

function mcp_call_tool(conn::MCPConn, tool::String, arguments::AbstractDict)
    result = _mcp_request(conn, "tools/call", Dict{String,Any}(
        "name"      => tool,
        "arguments" => arguments,
    ))
    # Flatten MCP content blocks into a single text payload for the agent.
    content = get(result, "content", Any[])
    parts = String[]
    for block in content
        if block isa AbstractDict
            get(block, "type", "") == "text" && push!(parts, string(get(block, "text", "")))
        end
    end
    text = isempty(parts) ? JSON.json(result) : join(parts, "\n")
    is_err = get(result, "isError", false) === true
    return is_err ? Dict("error" => text) : Dict("result" => text)
end

function mcp_disconnect(conn::MCPConn)
    try
        close(conn.proc.in)
    catch
    end
    try
        kill(conn.proc)
    catch
    end
end

function mcp_shutdown_all()
    for (_, conn) in MCP_CONNS
        mcp_disconnect(conn)
    end
    empty!(MCP_CONNS)
end

# ── Registry: read config, connect, expose tools to the agent ────────────────

# Namespaced tool id so external tools can never collide with built-ins and are
# self-describing in the UI. Matches the mcp__server__tool convention.
_mcp_tool_id(server::String, tool::String) = "mcp__$(server)__$(tool)"

# Register one server's tools into TOOL_MAP + DYNAMIC_SCHEMA.
function _mcp_register_conn!(conn::MCPConn)
    registered = String[]
    for t in conn.tools
        tool_name = string(get(t, "name", ""))
        isempty(tool_name) && continue
        id = _mcp_tool_id(conn.name, tool_name)

        # Callable: proxy the dispatch args straight through to the server.
        TOOL_MAP[id] = (args) -> begin
            c = get(MCP_CONNS, conn.name, nothing)
            c === nothing && return Dict("error" => "MCP connector '$(conn.name)' is not connected")
            mcp_call_tool(c, tool_name, args isa AbstractDict ? args : Dict{String,Any}())
        end

        # Visible to the model: MCP inputSchema is standard JSON Schema, which
        # the turn-time normalizer already lowercases/cleans — pass it through.
        params = get(t, "inputSchema", Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()))
        filter!(e -> e["name"] != id, DYNAMIC_SCHEMA)
        push!(DYNAMIC_SCHEMA, Dict{String,Any}(
            "name"        => id,
            "description" => string(get(t, "description", "MCP tool from '$(conn.name)'")),
            "parameters"  => params,
        ))
        push!(registered, id)
    end
    return registered
end

"""
    register_mcp_connectors!(root) -> Vector{String}

Read `connectors.json` from the runtime state dir and connect every enabled MCP
server, exposing its tools to the agent. Returns the list of registered tool
ids. Safe to call on boot: connectors are opt-in (`"enabled": true`), and any
single server failing is logged and skipped without affecting the others or the
engine's startup.

connectors.json shape:

    {
      "mcpServers": {
        "gmail":  { "command": "npx", "args": ["-y", "@some/mcp-gmail"], "enabled": true },
        "github": { "command": "npx", "args": ["-y", "@some/mcp-github"], "enabled": false }
      }
    }
"""
function register_mcp_connectors!(root::String="")
    path = _runtime_state_path("connectors.json"; root=root)
    isfile(path) || return String[]

    config = try
        JSON.parse(read(path, String))
    catch e
        @warn "connectors.json is not valid JSON — no MCP connectors loaded" exception=e
        return String[]
    end

    servers = get(config, "mcpServers", Dict{String,Any}())
    servers isa AbstractDict || return String[]

    all_registered = String[]
    for (name, spec) in servers
        spec isa AbstractDict || continue
        get(spec, "enabled", false) === true || continue   # opt-in only

        command = string(get(spec, "command", ""))
        isempty(command) && (@warn "MCP connector '$name' has no command — skipped"; continue)
        raw_args = get(spec, "args", String[])
        args = [string(a) for a in (raw_args isa AbstractVector ? raw_args : String[])]

        try
            cmd = `$command $args`
            conn = mcp_connect_stdio(string(name), cmd)
            MCP_CONNS[string(name)] = conn
            ids = _mcp_register_conn!(conn)
            append!(all_registered, ids)
            @info "MCP connector '$name' online — $(length(ids)) tool(s) registered"
        catch e
            @warn "MCP connector '$name' failed to connect — skipped, engine unaffected" exception=(e, catch_backtrace())
        end
    end
    return all_registered
end

# ─────────────────────────────────────────────────────────────────────────────
#  Vault — local credential store for connectors and tools
#
#  One place for API keys, tokens, and connection strings, so secrets never
#  live inside connectors.json (which documents commands) or in git.
#
#  Storage model: secrets.vault.json in the runtime state dir with owner-only
#  file permissions (0600) — the same trust model as ~/.aws/credentials or
#  ~/.netrc: protected from other users on the machine, readable by the engine.
#  (OS-keychain / encrypted-at-rest backends are a planned hardening upgrade;
#  the reference syntax below won't change when that lands.)
#
#  Referencing a secret: anywhere a connector env value is configured, the
#  string form  "vault:NAME"  resolves to the stored secret at spawn time.
#      "env": { "GITHUB_TOKEN": "vault:github_token" }
#
#  Agent access is deliberately one-way: the `vault` tool can set, list names,
#  and delete — it can NEVER read a value back out. Secret values flow only
#  into spawned connector processes, never into model context or chat logs.
#
#  Included into module BYTE after Tools.jl (uses _runtime_state_path and
#  registers into TOOL_MAP / TOOLS_SCHEMA) and before MCPClient.jl (which
#  calls resolve_secret when spawning connectors).
# ─────────────────────────────────────────────────────────────────────────────

const VAULT_FILE = "secrets.vault.json"

_vault_path(root::String="") = _runtime_state_path(VAULT_FILE; root=root)

function _vault_read(root::String="")::Dict{String,String}
    path = _vault_path(root)
    isfile(path) || return Dict{String,String}()
    try
        raw = JSON.parse(read(path, String))
        return Dict{String,String}(string(k) => string(v) for (k, v) in pairs(raw))
    catch e
        @warn "Vault file unreadable — treating as empty" exception=e
        return Dict{String,String}()
    end
end

function _vault_write(secrets::Dict{String,String}, root::String="")
    path = _vault_path(root)
    open(path, "w") do io
        write(io, JSON.json(secrets))
    end
    # Owner-only. On Windows chmod is best-effort (ACLs govern); never fatal.
    try
        chmod(path, 0o600)
    catch
    end
    return nothing
end

"""Store or overwrite a secret. Returns nothing; never echoes the value."""
function vault_set(name::String, value::String; root::String="")
    secrets = _vault_read(root)
    secrets[name] = value
    _vault_write(secrets, root)
    return nothing
end

"""Fetch a secret value. Internal use only — never expose through a tool."""
function vault_get(name::String; root::String="")::Union{String,Nothing}
    get(_vault_read(root), name, nothing)
end

function vault_delete(name::String; root::String="")
    secrets = _vault_read(root)
    haskey(secrets, name) || return false
    delete!(secrets, name)
    _vault_write(secrets, root)
    return true
end

vault_list(; root::String="") = sort(collect(keys(_vault_read(root))))

"""
    resolve_secret(value) -> String

Resolve the `"vault:NAME"` reference form to the stored secret. Any other
string passes through unchanged, so config values may be literals or vault
references interchangeably. An unknown vault name throws — better a loud
connector-spawn failure than silently exporting the literal string
"vault:github_token" as a credential.
"""
function resolve_secret(value::AbstractString; root::String="")::String
    startswith(value, "vault:") || return String(value)
    name = String(strip(value[7:end]))
    secret = vault_get(name; root=root)
    secret === nothing && error("Vault has no secret named '$name'. Store it first: vault set $name <value>")
    return secret
end

# ── Agent-facing tool (names only — values never leave the vault) ────────────

function tool_vault(args)
    action = lowercase(string(get(args, "action", "list")))
    root   = _project_root[]
    if action == "list"
        names = vault_list(root=root)
        return Dict("result" => isempty(names) ?
            "Vault is empty. Store a secret with action=set." :
            "Stored secrets (names only, values are never shown): $(join(names, ", "))")
    elseif action == "set"
        name  = strip(string(get(args, "name", "")))
        value = string(get(args, "value", ""))
        isempty(name)  && return Dict("error" => "action=set requires a 'name'")
        isempty(value) && return Dict("error" => "action=set requires a 'value'")
        vault_set(String(name), value; root=root)
        return Dict("result" => "Secret '$name' stored. Reference it in connectors.json as \"vault:$name\".")
    elseif action == "delete"
        name = strip(string(get(args, "name", "")))
        isempty(name) && return Dict("error" => "action=delete requires a 'name'")
        return vault_delete(String(name); root=root) ?
            Dict("result" => "Secret '$name' deleted.") :
            Dict("error"  => "No secret named '$name'.")
    end
    return Dict("error" => "Unknown action '$action'. Valid: list | set | delete")
end

TOOL_MAP["vault"] = tool_vault
push!(TOOLS_SCHEMA[1]["function_declarations"], Dict(
    "name"        => "vault",
    "description" => "Local credential vault for connector secrets (API keys, tokens). Actions: 'list' shows stored secret NAMES (values are never revealed), 'set' stores name+value, 'delete' removes one. Connectors reference secrets as \"vault:NAME\" in their env config.",
    "parameters"  => Dict(
        "type" => "OBJECT",
        "properties" => Dict(
            "action" => Dict("type" => "STRING", "description" => "list | set | delete", "enum" => ["list", "set", "delete"]),
            "name"   => Dict("type" => "STRING", "description" => "Secret name (for set/delete)"),
            "value"  => Dict("type" => "STRING", "description" => "Secret value (for set only; stored, never echoed back)")
        ),
        "required" => ["action"]
    )
))

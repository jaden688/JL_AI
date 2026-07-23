using HTTP

const DEFAULT_OPENROUTER_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
const DEFAULT_OPENROUTER_MODEL = "deepseek/deepseek-v4-flash"

abstract type AbstractBackend end

struct NoopBackend <: AbstractBackend
    config::Dict{String, Any}
end

struct OpenRouterBackend <: AbstractBackend
    config::Dict{String, Any}
end

const BACKEND_REGISTRY = Dict{String, Dict{String, Any}}(
    "noop-stub" => Dict{String, Any}(
        "id" => "noop-stub",
        "label" => "Stub (No backend)",
        "provider" => "noop",
    ),
    "openrouter" => Dict{String, Any}(
        "id" => "openrouter",
        "label" => "OpenRouter",
        "provider" => "openrouter",
        "endpoint" => DEFAULT_OPENROUTER_ENDPOINT,
        "model" => DEFAULT_OPENROUTER_MODEL,
        "api_key" => nothing,
        "timeout" => 120,
    )
)

const ACTIVE_BACKENDS = Dict{String, String}(
    "current" => "openrouter",
    "brain" => "openrouter",
    "tool" => "openrouter",
)

function set_backend_model!(backend_id::AbstractString, model_name::AbstractString)
    haskey(BACKEND_REGISTRY, backend_id) || return
    BACKEND_REGISTRY[String(backend_id)]["modelName"] = String(model_name)
    BACKEND_REGISTRY[String(backend_id)]["model_name"] = String(model_name)
    BACKEND_REGISTRY[String(backend_id)]["model"] = String(model_name)
end

function configure_backends!(; brain_id=nothing, tool_id=nothing)
    brain_id !== nothing && set_brain_backend_id!(String(brain_id))
    tool_id !== nothing && set_tool_backend_id!(String(tool_id))
    return ACTIVE_BACKENDS
end

function set_brain_backend_id!(backend_id::AbstractString)
    haskey(BACKEND_REGISTRY, backend_id) || return ACTIVE_BACKENDS
    ACTIVE_BACKENDS["brain"] = String(backend_id)
    ACTIVE_BACKENDS["current"] = String(backend_id)
    return ACTIVE_BACKENDS
end

function set_tool_backend_id!(backend_id::AbstractString)
    haskey(BACKEND_REGISTRY, backend_id) || return ACTIVE_BACKENDS
    ACTIVE_BACKENDS["tool"] = String(backend_id)
    return ACTIVE_BACKENDS
end

function get_backend(backend_id::Union{Nothing, AbstractString}=nothing; overrides=nothing)
    target_id = backend_id === nothing ? ACTIVE_BACKENDS["current"] : String(backend_id)
    config = deepcopy(get(BACKEND_REGISTRY, target_id, BACKEND_REGISTRY["noop-stub"]))
    if overrides isa AbstractDict
        merge!(config, Dict{String, Any}(string(key) => value for (key, value) in pairs(overrides)))
    end
    provider = String(get(config, "provider", "noop"))
    if provider == "openrouter"
        return OpenRouterBackend(config)
    end
    return NoopBackend(config)
end

get_brain_backend() = get_backend(ACTIVE_BACKENDS["brain"])
get_tool_backend() = get_backend(ACTIVE_BACKENDS["tool"])

function _message_content(messages)
    for message in Iterators.reverse(messages)
        if message isa AbstractDict && get(message, "role", nothing) == "user"
            return String(get(message, "content", ""))
        end
    end
    return ""
end

function generate(backend::NoopBackend, messages; options=Dict{String, Any}(), timeout=nothing)
    user_message = _message_content(messages)
    reply = isempty(user_message) ? "[NOOP BACKEND] This is a stub response. No real model was called." : user_message
    return reply, Dict{String, Any}("provider" => "noop", "status" => "ok", "model" => "noop-stub", "options" => options)
end

function generate(backend::OpenRouterBackend, messages; options=Dict{String, Any}(), timeout=nothing)
    endpoint = String(get(backend.config, "endpoint", DEFAULT_OPENROUTER_ENDPOINT))
    model = String(get(backend.config, "model", get(backend.config, "model_name", DEFAULT_OPENROUTER_MODEL)))
    
    api_key = get(backend.config, "api_key", nothing)
    api_key = api_key === nothing || isempty(String(api_key)) ? get(ENV, "OPENROUTER_API_KEY", "") : String(api_key)
    isempty(api_key) && return "[ERROR: OpenRouter API key is not set.]", Dict{String, Any}("error" => "api_key_missing")

    headers = [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $(api_key)",
        "HTTP-Referer" => "http://localhost:8081",
        "X-Title" => "JL Engine"
    ]

    payload = Dict{String, Any}("model" => model, "messages" => messages)
    if !isempty(options)
        haskey(options, "temperature") && (payload["temperature"] = options["temperature"])
        haskey(options, "top_p") && (payload["top_p"] = options["top_p"])
        haskey(options, "max_tokens") && (payload["max_tokens"] = options["max_tokens"])
    end

    try
        response = HTTP.post(endpoint, headers, JSON3.write(payload); readtimeout=(timeout === nothing ? get(backend.config, "timeout", 120) : timeout))
        data = _materialize_json(JSON3.read(String(response.body)))
        
        if haskey(data, "error")
            err_msg = data["error"] isa AbstractDict ? get(data["error"], "message", string(data["error"])) : string(data["error"])
            return "[ERROR: OpenRouter returned an error. Details: $(err_msg)]", Dict{String, Any}("error" => err_msg)
        end

        if haskey(data, "choices") && !isempty(data["choices"])
            choice = data["choices"][1]
            content = get(get(choice, "message", Dict()), "content", "")
            text = content === nothing ? "" : String(content)
            if isempty(strip(text))
                finish_reason = get(choice, "finish_reason", "unknown")
                return "[ERROR: Empty response from OpenRouter model $(model) (finish_reason=$(finish_reason)).]", Dict{String, Any}("error" => "empty_response", "model" => model, "backend" => "openrouter", "finish_reason" => finish_reason)
            end
            return text, Dict{String, Any}("model" => model, "backend" => "openrouter", "finish_reason" => get(choice, "finish_reason", "unknown"))
        end

        return "[ERROR: Unexpected response format from OpenRouter.]", Dict{String, Any}("error" => "bad_format", "raw" => data)
    catch exc
        if exc isa HTTP.Exceptions.StatusError
            body = String(exc.response.body)
            try
                data = _materialize_json(JSON3.read(body))
                if haskey(data, "error")
                    err_msg = data["error"] isa AbstractDict ? get(data["error"], "message", string(data["error"])) : string(data["error"])
                    return "[ERROR: OpenRouter returned an error. Details: $(err_msg)]", Dict{String, Any}("error" => err_msg, "status" => exc.status)
                end
            catch
            end
            return "[ERROR: OpenRouter returned HTTP $(exc.status).]", Dict{String, Any}("error" => body, "status" => exc.status)
        end
        return "[ERROR: Could not connect to OpenRouter.]", Dict{String, Any}("error" => sprint(showerror, exc))
    end
end

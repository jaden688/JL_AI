"""Reject cross-site browser sockets and unconfigured DNS rebinding hosts.

Native clients do not send Origin. This guard is not authentication: keep
the engine on a trusted local interface. Remote UI origins require explicit
configuration and an authenticated reverse proxy.
"""
function websocket_origin_allowed(authority::AbstractString, origin::AbstractString;
                                  trusted_origins::AbstractVector=String[])
    host = lowercase(strip(authority))
    isempty(host) && return false
    local_host = occursin(r"^(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{1,5})?$", host)
    configured = String[]
    for value in trusted_origins
        item = strip(value)
        m = match(r"^https?://([^/?#@\s]+)$", item)
        m === nothing && continue
        lowercase(m.captures[1]) == host && push!(configured, item)
    end
    (local_host || !isempty(configured)) || return false
    isempty(origin) && return true
    m = match(r"^https?://([^/?#@\s]+)$", origin)
    m === nothing && return false
    lowercase(m.captures[1]) == host || return false
    return local_host || origin in configured
end

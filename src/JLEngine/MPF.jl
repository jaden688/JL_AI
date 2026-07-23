function load_mpf_registry(registry_path::AbstractString)
    raw_registry = load_json_safely(registry_path)
    profiles = Dict{String, MPFProfile}()

    for (display_name, entry) in raw_registry
        entry isa AbstractDict || continue
        agent_file = get(entry, "agent_file", nothing)
        agent_file isa AbstractString || continue
        tags = [String(tag) for tag in get(entry, "tags", Any[]) if tag isa AbstractString]
        profiles[String(display_name)] = MPFProfile(
            agent_file=String(agent_file),
            default_memory_mode=get(entry, "default_memory_mode", nothing),
            default_backend_id=get(entry, "default_backend_id", nothing),
            drive_type=get(entry, "drive_type", nothing),
            tags=tags,
        )
    end

    return profiles
end

load_agent_file(path::AbstractString) = load_json_safely(path)

function get_llm_boot_prompt(agent_config::AbstractDict, target::AbstractString="generic_llm")
    profiles = get(agent_config, "llm_profiles", nothing)
    profiles isa AbstractDict || return ""

    profile = get(profiles, target, nothing)
    if profile isa AbstractDict
        prompt = get(profile, "boot_prompt", nothing)
        prompt isa AbstractString && return String(prompt)
    end

    generic = get(profiles, "generic_llm", nothing)
    if generic isa AbstractDict
        prompt = get(generic, "boot_prompt", nothing)
        prompt isa AbstractString && return String(prompt)
    end

    return ""
end

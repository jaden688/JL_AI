# Reproduce Backends.jl OpenRouter call exactly, capturing the REAL exception.
import Pkg
using HTTP, JSON3

# load key from .env the same way App.jl does
key = ""
for ln in eachline(".env")
    m = match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", strip(ln))
    m === nothing && continue
    m[1] == "OPENROUTER_API_KEY" && (global key = strip(m[2], ['"','\'']))
end
println("key present: ", !isempty(key), " len=", length(key))

for model in ("anthropic/claude-3-haiku", "deepseek/deepseek-v4-flash")
    println("\n=== model: ", model, " ===")
    body = JSON3.write(Dict(
        "model" => model,
        "messages" => [Dict("role"=>"user","content"=>"say hi in one word")],
    ))
    headers = ["Authorization"=>"Bearer $key", "Content-Type"=>"application/json"]
    try
        r = HTTP.post("https://openrouter.ai/api/v1/chat/completions", headers, body; readtimeout=30)
        println("HTTP ", r.status)
        d = JSON3.read(String(r.body))
        println("reply: ", d.choices[1].message.content)
    catch e
        println("THREW: ", typeof(e))
        println(sprint(showerror, e)[1:min(end,800)])
    end
end

using Test

include("test_websocket_security.jl")

include(joinpath(@__DIR__, "..", "BYTE", "src", "Schema.jl"))
include(joinpath(@__DIR__, "..", "BYTE", "src", "Tools.jl"))

@testset "execute_code language handling" begin
    inferred = tool_execute_code(Dict(
        "code" => "import os\nprint('python:' + os.name)"
    ))
    @test !haskey(inferred, "error")
    @test inferred["language"] == "python"
    @test occursin("python:", inferred["stdout"])

    explicit = tool_execute_code(Dict(
        "language" => "python",
        "code" => "print('explicit-python')"
    ))
    @test !haskey(explicit, "error")
    @test explicit["language"] == "python"
    @test occursin("explicit-python", explicit["stdout"])

    rejected = tool_execute_code(Dict(
        "language" => "ruby",
        "code" => "puts 'nope'"
    ))
    @test occursin("Unsupported language", rejected["error"])

    failed = tool_execute_code(Dict(
        "language" => "python",
        "code" => "import sys\nprint('stdout-marker', flush=True)\nprint('stderr-marker', file=sys.stderr, flush=True)\nsys.exit(2)"
    ))
    @test haskey(failed, "error")
    @test occursin("stdout-marker", failed["output"])
    @test occursin("stderr-marker", failed["output"])
end

include("test_a2a_discovery.jl")
include("test_a2a_billing.jl")
include("test_a2a_protocol.jl")

using Test
const _project_root = Ref("")
source = Meta.parseall(read("BYTE/src/Tools.jl", String))
wanted = Set([:_get_named_arg, :_infer_execute_language, :_python_command, :tool_execute_code])
for node in source.args
    node isa Expr && node.head == :function || continue
    signature = node.args[1]
    signature isa Expr && signature.head == :call || continue
    signature.args[1] in wanted && Core.eval(Main, node)
end
@testset "production execute_code capture" begin
 for _ in 1:5
  r=tool_execute_code(Dict("code"=>"import sys\nprint('stdout-marker',flush=True)\nprint('stderr-marker',file=sys.stderr,flush=True)"))
  @test !haskey(r,"error")
  @test occursin("stdout-marker",r["stdout"])
  @test occursin("stderr-marker",r["stdout"])
 end
 r=tool_execute_code(Dict("language"=>"python","code"=>"import sys\nprint('before-failure',flush=True)\nsys.exit(2)"))
 @test haskey(r,"error")
 @test occursin("before-failure",r["output"])
 @test occursin("Unsupported language",tool_execute_code(Dict("language"=>"ruby","code"=>"x"))["error"])
end

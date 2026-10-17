using Test

include(joinpath(@__DIR__, "..", "BYTE", "src", "WebSecurity.jl"))

@testset "WebSocket browser boundary" begin
    @test websocket_origin_allowed("127.0.0.1:8081", "http://127.0.0.1:8081")
    @test websocket_origin_allowed("localhost:8081", "http://localhost:8081")
    @test websocket_origin_allowed("[::1]:8081", "http://[::1]:8081")
    @test websocket_origin_allowed("127.0.0.1:8081", "") # native MCP client
    @test !websocket_origin_allowed("127.0.0.1:8081", "https://attacker.example")
    @test !websocket_origin_allowed("127.0.0.1:8081", "null")
    @test !websocket_origin_allowed("rebound.attacker.example:8081", "http://rebound.attacker.example:8081")
    @test !websocket_origin_allowed("localhost:8081", "http://localhost:8082")
    @test !websocket_origin_allowed("localhost:8081", "http://user@localhost:8081")
    @test !websocket_origin_allowed("localhost:8081", "http://localhost:8081/path")
    @test !websocket_origin_allowed("", "")
    @test websocket_origin_allowed("engine.example", "https://engine.example"; trusted_origins=["https://engine.example"])
    @test !websocket_origin_allowed("engine.example", "https://attacker.example"; trusted_origins=["https://engine.example"])
end

using Test, HTTP, JLEngine
port=18381
@async JLEngine.BYTE.serve((current_agent_name="security-test",); host="127.0.0.1",port=port)
ready=false
for _ in 1:50
 try
  HTTP.get("http://127.0.0.1:$port/health"; retry=false)
  global ready=true
  break
 catch
  sleep(0.1)
 end
end
@test ready
@testset "live BYTE WebSocket handshake" begin
 for origin in ["https://attacker.example", "null"]
  response=HTTP.get("http://127.0.0.1:$port/";
   headers=["Upgrade"=>"websocket", "Connection"=>"Upgrade", "Sec-WebSocket-Version"=>"13", "Sec-WebSocket-Key"=>"dGhlIHNhbXBsZSBub25jZQ==", "Origin"=>origin],
   status_exception=false, retry=false, closeimmediately=true)
  status=response.status
  @test status==403
 end
 for headers in [Pair{String,String}[],["Origin"=>"http://127.0.0.1:$port"]]
  connected=Ref(false)
  HTTP.WebSockets.open("ws://127.0.0.1:$port"; headers=headers, closeimmediately=true) do ws
   connected[]=true
  end
  @test connected[]
 end
end

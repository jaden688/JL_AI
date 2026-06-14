import asyncio, json
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def main():
    params = StdioServerParameters(command="python", args=["mcp_server/server.py"])
    async with stdio_client(params) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            tools = await s.list_tools()
            print("=== TOOLS ===")
            for t in tools.tools:
                print(f"  - {t.name}")
            async def call(name, args=None):
                print(f"\n=== CALL {name}({args or {}}) ===")
                res = await s.call_tool(name, args or {})
                for c in res.content:
                    print(getattr(c, "text", str(c))[:1500])
            await call("get_engine_state")
            await call("get_telemetry", {"limit": 8})
            await call("list_forged_tools")
            await call("get_thoughts", {"limit": 5, "thought_type": "all"})

asyncio.run(main())

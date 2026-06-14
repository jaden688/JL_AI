import asyncio, json
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

def show(title, res):
    print(f"\n========== {title} ==========")
    for c in res.content:
        t = getattr(c, "text", str(c))
        print(t[:1800])

async def main():
    params = StdioServerParameters(command="python", args=["mcp_server/server.py"])
    async with stdio_client(params) as (r, w):
        async with ClientSession(r, w) as s:
            init = await s.initialize()
            print("CONNECTED to MCP server:", init.serverInfo.name, "v"+str(init.serverInfo.version))
            tools = await s.list_tools()
            print("Tools available:", ", ".join(t.name for t in tools.tools))
            res = await s.list_resources()
            print("Resources:", ", ".join(str(x.uri) for x in res.resources))

            show("ENGINE STATE", await s.call_tool("get_engine_state", {}))
            show("LAST 6 TELEMETRY", await s.call_tool("get_telemetry", {"limit": 6}))
            show("THOUGHTS (diary, 4)", await s.call_tool("get_thoughts", {"limit": 4, "thought_type": "all"}))
            show("FORGED/BUILTIN TOOLS", await s.call_tool("list_forged_tools", {}))
            show("MEMORY (recent 6)", await s.call_tool("query_memory", {"limit": 6}))
            show("KNOWLEDGE (engine_capabilities)", await s.call_tool("get_knowledge", {"domain": "engine_capabilities", "limit": 4}))

asyncio.run(main())

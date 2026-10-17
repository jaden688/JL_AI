import asyncio, importlib.util, json, pathlib, tempfile
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock
from aiohttp.test_utils import TestClient, TestServer

async def main():
    spec=importlib.util.spec_from_file_location('rayforge_review',str(pathlib.Path(__import__('sys').argv[1]) / 'rayforge_bridge/server.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    machine=SimpleNamespace(is_connected=lambda:True,heads=[object()])
    calls=[]
    async def send_job(m): calls.append('send_job')
    async def export(path): path.write_text('mock gcode')
    mod.STATE=SimpleNamespace(ensure_ready=AsyncMock(),machine=machine,machine_cmd=SimpleNamespace(send_job=send_job,set_power=lambda *a:calls.append(('power',a[1]))),editor=SimpleNamespace(export_gcode_to_path=export))
    async with TestClient(TestServer(mod.build_app())) as client:
        r=await client.post('/machine/send_job',headers={'Origin':'https://untrusted.example'});print('unauthenticated foreign-origin job:',r.status,await r.text(),'mock calls',calls)
        r=await client.post('/machine/set_power',json={'power_pct':61});print('power limit control:',r.status,await r.text())
        r=await client.post('/machine/set_power',data='{"power_pct": NaN}',headers={'Content-Type':'application/json'});print('nonfinite power:',r.status,await r.text(),'mock calls',calls)
        with tempfile.TemporaryDirectory() as td:
            output=pathlib.Path(td)/'outside-project'/'proof.gcode'
            r=await client.post('/export_gcode',json={'output_path':str(output)});print('arbitrary export path:',r.status,'file created',output.exists())
asyncio.run(main())

# Validation details

- Julia 1.10.10: `julia --project=. --compile=min -O0 --compiled-modules=no test/runtests.jl` passed **83 assertions**: 13 WebSocket boundary, 10 execute-code, 24 A2A discovery, 7 billing, 29 protocol. See julia-tests.txt.
- Formal `Pkg.test(; allow_reresolve=false, julia_args=["--compile=min", "-O0", "--compiled-modules=no"])` with `JULIA_PKG_PRECOMPILE_AUTO=0` passed the same entire suite; see julia-pkg-tests.txt.
- The first default Pkg.test attempt hit a precompiler subprocess failure (`fatal library error, lookup self`) in this environment. Reducing compilation and disabling automatic precompilation allowed the formal complete run to finish.
- Python 3.12: Julian 12 passed; MCP smoke 7/7 passed, plus a real temporary SQLite parameterized-read control.
- Node 24.19.0: clean `npm ci`, ESLint, TypeScript, production build and production dependency audit passed.
- Node 20: production Next.js build passed independently via `npx --package=node@20 node node_modules/next/dist/bin/next build`; see node20-build.txt.
- Five local built-page HTTP responses and Sharp PNG encode/decode passed.
- Patched Python package controls and `pip check`: passed. Entire root requirements install remains blocked by missing editable projects; compatibility of every optional ML library is not established.
- Full dependency audit limitations, external account restrictions, historical credential rotation and incomplete Rayforge/genome backend remain as described in REPORT.md.

- Live BYTE WebSocket handshake: 4/4 passed against the actual server (foreign and null origins rejected with HTTP 403; native and same-origin connections accepted). Upgrade probes used isolated connections to avoid reusing an upgraded/closed HTTP client connection. No tool messages were sent. Reproducer: `julia --project=. --compile=min -O0 --compiled-modules=no docs/audits/2026-10-17/websocket_handshake.jl`.

- Python websockets 13.1 against live BYTE: native/same-origin accepted, foreign/null origins returned HTTP 403 (**4/4 passed**). Rejection responses now include Content-Length for clients that cannot parse chunked handshake errors. Full Pkg.test rerun after this header change: **83/83 passed**.

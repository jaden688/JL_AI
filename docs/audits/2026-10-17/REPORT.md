# JL_AI repair and security review — 2026-10-17

Base: `5dd8bec76607c776ff638eb5a6fb4d507ce769f8` on `main`.
This is a targeted source, dependency, CI, PR, and branch review, not a claim
that every application path or historical secret has been exhaustively audited.
No hardware, paid model, or production deployment was operated.

## Dependency repairs

- Next.js 15.5.21 → 15.5.28. The audit reported Windows-hosted and image
  optimization RCE advisories, plus SSG/ISR cache poisoning. Advisory ranges
  are retained in `npm-before.json`; the updated graph is in `npm-after.json`.
- PostCSS 8.5.30 overrides both the direct development dependency and Next's
  older transitive copy. This covers CSS source-map path traversal/disclosure
  and the older stringify XSS advisory.
- Sharp 0.35.5 replaces the vulnerable image-processing dependency chain.
  PostCSS selector parser 7.1.6, nanoid 3.3.20, source-map-js 1.2.2, and
  compatible Browserslist dependencies also replace vulnerable versions.
- Ten Python pins were updated in **both** identical root requirements files:
  aiohttp 3.14.4, anyio 4.15.1, CairoSVG 2.9.1, GitPython 3.1.60,
  httplib2 0.32.0, MCP 1.30.0, multidict 6.9.1, NLTK 3.10.3,
  PyJWT 2.15.1, and tornado 6.5.9. The MCP runtime minimum is now 1.30.0.
- Across the 216 exact Python pins, affected distributions declined from
  16 to 7; unique package/advisory-ID pairs declined from 79 to 10.
  These are advisory identifiers, not a count of independently exploitable bugs.

Production npm dependencies audit clean. The **full** npm audit remains red:
`braces@3.0.3` is affected by GHSA-vfj7-8cjw-p6xm. Seven affected graph nodes
include Tailwind and its callers, including the newly installed lint tooling.
There is no patched release in the current braces line. An automatic Tailwind
4 migration was deliberately avoided because it changes the build/configuration.

Remaining affected root Python pins: accelerate 1.13.0, cryptography 48.0.1,
datasets 4.8.4, fsspec 2025.12.0, litellm 1.84.0, NLTK 3.10.3, and
transformers 5.5.0. Some advisories have no published fix; others require
larger upgrades or ML/provider compatibility testing. See `python-pins-after.json`.
Unpinned dependencies and missing editable local projects are outside this
exact-pin comparison. A complete root install is not verified: pip's dry run
fails because `src/jl-engine-local/src/jl_engine_local` is absent.

## Source and startup repairs

- Compose previously published ports 8081/8082 on every host interface.
  They now publish on 127.0.0.1. The engine permits tool execution and must
  not be exposed as an unauthenticated public service.
- BYTE now rejects foreign browser WebSocket origins and unconfigured Host
  authorities before upgrade. Loopback browser and native clients remain
  supported. Explicit remote origins use `SPARKBYTE_ALLOWED_ORIGINS`.
  **This is not authentication.** A reachable native client can spoof Host
  and omit Origin. Other containers on the same network are also a trust
  boundary. Remote use requires an authenticated proxy or a separate auth design.
- Julian's service passed `genome_dir` to a constructor that does not support
  it and called missing methods during import. Core startup is restored;
  unavailable genome endpoints explicitly return HTTP 501. Existing optional
  integration code remains available when its backend is implemented.
- `execute_code` could lose stdout while asynchronous IOBuffer-copy tasks were
  still writing. A temporary file descriptor now captures stdout/stderr before
  reading, including output from failed child processes.
- Missing PWA manifest and 192/512px icons prevented engine module loading.
  Original assets were recovered verbatim from `public-main`, preserving work.
- AGENTS.md incorrectly claimed custom MCP authentication/path sandbox controls
  existed on main. It now describes the actual transport trust boundary.

## CI diagnosis and changes

GitHub check annotations on current main job 117486019011 and PR #12 job
90384485969 state: “The job was not started because your account is locked
due to a billing issue.” Historical logs were unavailable. This is an external
account restriction, not evidence of a failing application test.

Vercel statuses on PRs #8/#10/#12 explicitly say “Account is blocked.”
Code changes cannot lift that restriction.

There was also an independently reproduced latent code-side CI failure:
`next lint` prompted interactively because ESLint was not configured. A real
ESLint configuration and noninteractive lint command now exist. CI uses strict
`npm ci`, typechecks, audits production npm dependencies, and tests Julian.
The Julia job now blocks failures; the local full suite passed 83 assertions.

## PR decisions

| PR | Evidence | Decision |
|---|---|---|
| #8 | Proposes 15.5.16; main already received 15.5.21 via merged #11; conflicts | Closed; superseded by merged repair #13 |
| #12 | PostCSS 8.5.18/nanoid 3.3.16; historical Snyk passed, but newer advisories affect these versions | Closed; superseded by merged repair #13 |
| #10 | Unique Rayforge integration; source and mocked-route tests expose security gaps | Preserved open as draft; do not merge |

PR #8's Sourcery result consisted of one Next vulnerability (CVE-2026-45109)
and fourteen native-image dependency license-policy flags. License flags are
not fourteen additional exploit findings; licenses and application code were
preserved. The exact private Snyk failure detail was unavailable. Historical
Snyk statuses alone do not establish current security.

### Rayforge findings

`rayforge_review.py <path-to-PR-10-checkout>` safely exercises an in-process
aiohttp test server with fake machine/editor objects. Observed:

- Foreign-origin, unauthenticated `/machine/send_job`: HTTP 200 and fake job
  dispatch. No authentication/bind safeguard exists in the bridge.
- `power_pct=61`: correctly rejected with HTTP 403 against the 60% limit.
- Nonfinite `power_pct=NaN`: HTTP 200 and fake power dispatch.
- `/export_gcode` accepts an arbitrary absolute path and creates a file outside
  the project. MCP wrappers do not constrain this path either.
- Source review shows generated jobs bypass the direct set-power ceiling;
  the claimed job-wide clamp was not verified or implemented.

No physical machine, serial port, or live Rayforge configuration was touched.
Real Rayforge/Julia/hardware compatibility remains unverified; preserve PR #10
until these controls and the integration tests are implemented.

## Agent and branch cleanup

All eight remaining `data/agents/*.md` variants exactly matched the checked-in
JSON-to-Markdown generator's output and had matching JSON files. Only those
generated copies were removed. Every JSON agent is unchanged and parses.
The prior main deletions of Balth.md, JL_Agents.mpf.md, and SparkByte_Full.md
remain intact. Root agent guidance and `.github/agents/sparkbyte.agent.md`
were preserved because they serve separate purposes.

No remote branch was deleted. `branches.json` records exact heads, divergence,
and non-equivalent patch counts. Proposed deletion, awaiting the user's required review:

- `snyk-fix-6404e380ed6f96e361295595e9e42ab8`
- `dependabot/npm_and_yarn/web/npm_and_yarn-f436965d76`
- `security/repository-repair-2026-10-17` (repair PR #13 is merged; its final tree exactly matches main)

Preserve `copilot/analyze-security-issues` (26 non-equivalent patches),
`copilot/review-repo-status` (48), `feature/caido-integration` (1),
`public-main` (5), and the Rayforge worktree branch (2). Names alone do not
make these branches obsolete. The recovered PWA assets demonstrate why
deleting them without reviewing unique work would be unsafe.

## Historical credential

A credential-pattern history scan found a previously committed Gemini key
in `test/test_dynamic_tools.jl` in commit `acbe0b8`, later redacted in
`f4f62c9`. Current-source pattern scanning found no matching credential.
Revocation/rotation is still required; redaction cannot revoke a key.
No secret value is included here. Git history was not rewritten.

## Validation

- Clean npm install, lint, TypeScript, Next production build: passed.
- Five built page HTTP checks: passed (/, /features, /how-it-works,
  /operators, /enterprise). Sharp PNG encode/decode: passed.
- `npm audit --omit=dev`: zero vulnerabilities. Full audit: seven affected
  development graph nodes, as described above.
- MCP and Docker resolved requirement audits: zero known vulnerabilities.
- Ten patched Python distributions: imports and representative local behavior
  controls passed; `pip check` reported no broken installed requirements.
- Julian pytest: 12 passed, one upstream Starlette/httpx deprecation warning.
- MCP smoke: 7/7 passed. This checks error-path callability without live DBs;
  an additional temporary real-SQLite read/parameterization control passed.
- WebSocket browser-boundary unit tests: 13 passed. Live BYTE handshake:
  4/4 passed, rejecting foreign/null origins while accepting native/same-origin
  clients. No tool payloads were sent.
- Extracted production execute-code capture controls: 18 passed. Full Julia
  rerun also passed its 10 execute-code assertions before reaching later tests.
- Compose YAML host-publishing check and `git diff --check`: passed.
- No Docker daemon is installed; a container build was not verified.
- GitHub Actions and Vercel remain account-blocked. Private Dependabot alerts
  were unavailable through the connector; independent package audits provide
  the dependency evidence, not a claim that every private alert is closed.

Full Julia-suite and formal Pkg.test reruns passed all 83 assertions.
See VALIDATION.md and julia-pkg-tests.txt for exact commands and limitations.

## Post-publication service status

The new repair PR #13 received a Vercel failure (`Account is blocked.`)
and a Snyk error (`You have used your limit of private tests`). These prevent
external verification; neither is an application-test failure. Independent
local audit and validation results above remain the verification evidence.

## Final repository state

Repair PR #13 was squash-merged as `47db745619fdebac8daf750b5f994e29637174a7`.
Its tree `7fe80024a5a52067234c8db2a8caa0d3d5fe5451` exactly matches the tested
checkout. PRs #8 and #12 are closed as superseded; #10 is the sole remaining
open PR and is a draft with its blockers documented. No remote branch was
deleted, no JSON agent changed, and no license or existing history was rewritten.
The temporary local Rayforge review worktree was removed after testing.

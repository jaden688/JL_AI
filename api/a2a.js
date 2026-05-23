// Vercel serverless proxy: forwards /api/a2a/* → A2A_REMOTE_URL
// Set A2A_REMOTE_URL in Vercel dashboard, e.g. "https://my-host.com:8082"
import { request as httpsRequest } from "https";
import { request as httpRequest } from "http";

export const config = { api: { bodyParser: false } };

export default function handler(req, res) {
  const remoteBase = process.env.A2A_REMOTE_URL;
  if (!remoteBase) {
    res.status(500).json({ error: "A2A_REMOTE_URL not configured" });
    return;
  }

  // Strip the /api/a2a prefix; keep the rest (including query string)
  const downstream = req.url.replace(/^\/api\/a2a/, "") || "/";
  const target = `${remoteBase}${downstream}`;

  const lib = target.startsWith("https") ? httpsRequest : httpRequest;

  const { host: _drop, ...forwardHeaders } = req.headers;
  const proxy = lib(target, { method: req.method, headers: forwardHeaders }, (upstream) => {
    res.statusCode = upstream.statusCode;
    for (const [k, v] of Object.entries(upstream.headers)) {
      res.setHeader(k, v);
    }
    upstream.pipe(res);
  });

  proxy.on("error", (err) => {
    console.error("A2A proxy error:", err.message);
    if (!res.headersSent) res.status(502).json({ error: "Bad gateway" });
  });

  req.pipe(proxy);
}

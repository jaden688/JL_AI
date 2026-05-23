import { NextRequest } from "next/server";

const REMOTE = process.env.A2A_REMOTE_URL;

async function proxy(req: NextRequest) {
  if (!REMOTE) {
    return Response.json({ error: "A2A_REMOTE_URL not configured" }, { status: 500 });
  }

  const url = new URL(req.url);
  // Strip /api/a2a prefix, preserve the rest of the path + query string
  const downstream = url.pathname.replace(/^\/api\/a2a/, "") || "/";
  const target = `${REMOTE}${downstream}${url.search}`;

  const headers = new Headers(req.headers);
  headers.delete("host");

  const hasBody = req.method !== "GET" && req.method !== "HEAD";

  const upstream = await fetch(target, {
    method: req.method,
    headers,
    body: hasBody ? req.body : undefined,
    // @ts-ignore — needed for streaming request bodies
    duplex: "half",
  });

  return new Response(upstream.body, {
    status: upstream.status,
    headers: upstream.headers,
  });
}

export const GET = proxy;
export const POST = proxy;
export const PUT = proxy;
export const PATCH = proxy;
export const DELETE = proxy;
export const HEAD = proxy;
export const OPTIONS = proxy;

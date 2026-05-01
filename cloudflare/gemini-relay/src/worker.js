// hohome-gemini-relay
//
// Routes:
//   GET  /healthz                       → "ok"
//   ANY  /v1beta/<...>                  → REST proxy to generativelanguage.googleapis.com
//   GET  /ws/live?model=<id>            → WebSocket relay to Gemini Live BidiGenerateContent
//
// Auth:
//   Header  X-Relay-Secret: <RELAY_SECRET>   (REST)
//   Query   ?auth=<RELAY_SECRET>             (WebSocket — browsers/Ruby ws clients
//                                             can't always set custom headers on upgrade)
//
// Secrets injected at runtime:
//   env.GEMINI_API_KEY  — appended as ?key= to upstream
//   env.RELAY_SECRET    — shared with the SU plugin

const UPSTREAM_REST = "https://generativelanguage.googleapis.com";
const UPSTREAM_WS   = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/healthz") {
      return new Response("ok\n", { headers: { "content-type": "text/plain" } });
    }

    if (url.pathname === "/ws/live") {
      return handleLiveWebSocket(request, env, url);
    }

    if (url.pathname.startsWith("/v1beta/")) {
      return handleRest(request, env, url);
    }

    return new Response("not found\n", { status: 404 });
  },
};

function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function handleRest(request, env, url) {
  const supplied = request.headers.get("x-relay-secret") || "";
  if (!timingSafeEqual(supplied, env.RELAY_SECRET || "")) {
    return new Response("forbidden\n", { status: 403 });
  }

  const upstream = new URL(UPSTREAM_REST + url.pathname + url.search);
  upstream.searchParams.set("key", env.GEMINI_API_KEY);

  const headers = new Headers(request.headers);
  headers.delete("x-relay-secret");
  headers.delete("host");
  headers.delete("cf-connecting-ip");
  headers.delete("cf-ray");

  const init = {
    method: request.method,
    headers,
    body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
  };

  const resp = await fetch(upstream.toString(), init);
  return new Response(resp.body, {
    status: resp.status,
    headers: resp.headers,
  });
}

async function handleLiveWebSocket(request, env, url) {
  if (request.headers.get("upgrade") !== "websocket") {
    return new Response("expected websocket upgrade\n", { status: 426 });
  }

  const auth = url.searchParams.get("auth") || "";
  if (!timingSafeEqual(auth, env.RELAY_SECRET || "")) {
    return new Response("forbidden\n", { status: 403 });
  }

  const model = url.searchParams.get("model") || "gemini-2.0-flash-exp";

  const upstreamUrl = new URL(UPSTREAM_WS);
  upstreamUrl.searchParams.set("key", env.GEMINI_API_KEY);

  const upstreamResp = await fetch(upstreamUrl.toString(), {
    headers: { Upgrade: "websocket" },
  });
  const upstream = upstreamResp.webSocket;
  if (!upstream) {
    return new Response("upstream did not upgrade\n", { status: 502 });
  }

  const pair = new WebSocketPair();
  const [client, server] = [pair[0], pair[1]];

  server.accept();
  upstream.accept();

  // The plugin is expected to send the BidiGenerateContent setup message first.
  // We just pipe bytes both ways. If you want the relay to enforce/inject the
  // model, do it here by intercepting the first client message and rewriting
  // setup.model.
  void model; // currently unused — client sends setup with model id

  const closeBoth = (code, reason) => {
    try { server.close(code, reason); } catch {}
    try { upstream.close(code, reason); } catch {}
  };

  server.addEventListener("message", (e) => {
    try { upstream.send(e.data); } catch (err) { closeBoth(1011, "upstream send failed"); }
  });
  upstream.addEventListener("message", (e) => {
    try { server.send(e.data); } catch (err) { closeBoth(1011, "client send failed"); }
  });

  server.addEventListener("close", (e) => {
    try { upstream.close(e.code, e.reason); } catch {}
  });
  upstream.addEventListener("close", (e) => {
    try { server.close(e.code, e.reason); } catch {}
  });

  server.addEventListener("error", () => closeBoth(1011, "client error"));
  upstream.addEventListener("error", () => closeBoth(1011, "upstream error"));

  return new Response(null, { status: 101, webSocket: client });
}

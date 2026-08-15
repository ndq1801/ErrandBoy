#!/usr/bin/env node
/**
 * jina-fresh - minimal MCP stdio server (zero dependencies) wrapping the
 * Jina Reader API with cache bypass.
 *
 * Why this exists:
 * - The previous server (npm package `jina-mcp-tools`) cached page content
 *   per URL in an in-process LRU with NO TTL, so any URL read twice during
 *   the gateway's lifetime returned the stale first result (e.g. a weather
 *   forecast read at 07:30 today returned yesterday's content).
 * - Jina's server-side cache (TTL ~1h) also returns stale content for
 *   real-time pages when the same URL is fetched within the hour.
 *
 * This server fixes both:
 * - no client-side cache of its own
 * - every request to r.jina.ai is sent with `X-No-Cache: true` so the
 *   server-side cache is bypassed and the live page is fetched.
 *
 * Replaces `npx -y jina-mcp-tools --transport stdio` in config.yaml:
 *   jina:
 *     command: node
 *     args: ["/app/mcp/jina-fresh.js"]
 *     env:
 *       JINA_API_KEY: ${JINA_API_KEY}
 */
"use strict";

const readline = require("readline");
const https = require("https");

const SERVER_INFO = { name: "jina-fresh", version: "1.0.0" };
const JINA_READER_ENDPOINT = "https://r.jina.ai/";
const DEFAULT_TIMEOUT_MS = 60000; // X-Timeout sent to Jina Reader
const ABORT_SLACK_MS = 15000; // client abort slightly after server timeout

const API_KEY = process.env.JINA_API_KEY || "";

// ---------------------------------------------------------------------------
// r.jina.ai client (mirrors jina-mcp-tools request shape + X-No-Cache)
// ---------------------------------------------------------------------------

function postJsonOnce(urlStr, headers, body, timeoutMs) {
  return new Promise((resolve, reject) => {
    let u;
    try {
      u = new URL(urlStr);
    } catch (err) {
      reject(new Error(`Invalid URL: ${urlStr}`));
      return;
    }
    const req = https.request(
      {
        hostname: u.hostname,
        port: u.port || 443,
        path: u.pathname + u.search,
        method: "POST",
        headers,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () =>
          resolve({
            statusCode: res.statusCode,
            headers: res.headers,
            body: Buffer.concat(chunks).toString("utf8"),
          })
        );
      }
    );
    req.setTimeout(timeoutMs, () =>
      req.destroy(new Error(`Request timed out after ${timeoutMs}ms`))
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

async function postWithRedirects(urlStr, headers, body, timeoutMs, maxRedirects) {
  for (let i = 0; i <= maxRedirects; i++) {
    const res = await postJsonOnce(urlStr, headers, body, timeoutMs);
    const loc = res.headers.location;
    if ([301, 302, 303, 307, 308].includes(res.statusCode) && loc) {
      urlStr = new URL(loc, urlStr).href;
      continue;
    }
    return res;
  }
  throw new Error("Too many redirects while reaching Jina Reader");
}

async function readUrl(url, timeoutMs) {
  const body = JSON.stringify({ url });
  const headers = {
    "Content-Type": "application/json",
    Accept: "application/json",
    "X-Md-Link-Style": "discarded",
    "X-With-Links-Summary": "all",
    "X-Retain-Images": "none",
    "X-No-Cache": "true", // bypass Jina's ~1h server-side cache
    DNT: "1", // do not track/cache this URL on Jina's side
    "X-Timeout": String(Math.max(1, Math.round(timeoutMs / 1000))), // seconds, per docs.jina.ai/reader
  };
  if (API_KEY) headers["Authorization"] = `Bearer ${API_KEY}`;

  const res = await postWithRedirects(
    JINA_READER_ENDPOINT,
    headers,
    body,
    timeoutMs + ABORT_SLACK_MS,
    3
  );

  let envelope = null;
  try {
    envelope = JSON.parse(res.body);
  } catch (err) {
    // not JSON - surface raw body as an error hint
  }

  if (
    res.statusCode >= 200 &&
    res.statusCode < 300 &&
    envelope &&
    typeof envelope.data === "object" &&
    typeof envelope.data.content === "string"
  ) {
    return envelope.data.content;
  }

  const detail =
    (envelope && (envelope.statusText || envelope.status || envelope.error)) ||
    `HTTP ${res.statusCode}`;
  throw new Error(
    `Jina Reader error: ${detail}${res.body ? ` (${res.body.slice(0, 300)})` : ""}`
  );
}

// ---------------------------------------------------------------------------
// MCP stdio server (JSON-RPC 2.0, newline-delimited messages)
// ---------------------------------------------------------------------------

const TOOLS = [
  {
    name: "jina_reader",
    description:
      "Read a web page and return its content as clean markdown, fetched FRESH from the live site (Jina Reader with cache bypass - never returns cached/stale content). Use for articles, docs, weather forecasts, or any page whose content changes over time. Pass the full URL starting with http(s)://.",
    inputSchema: {
      type: "object",
      properties: {
        url: {
          type: "string",
          description:
            "Full URL of the page to read, e.g. https://example.com/page",
        },
        timeout: {
          type: "number",
          description:
            "Optional request timeout in milliseconds (default 60000)",
        },
      },
      required: ["url"],
    },
  },
];

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function sendResult(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function sendError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handleToolCall(name, args) {
  if (name === "jina_reader") {
    const url = args && typeof args.url === "string" ? args.url.trim() : "";
    if (!url) throw new Error("Missing required argument: url");
    const timeout =
      args && Number.isFinite(args.timeout) && args.timeout > 0
        ? Math.round(args.timeout)
        : DEFAULT_TIMEOUT_MS;
    const content = await readUrl(url, timeout);
    return { content: [{ type: "text", text: content }], isError: false };
  }
  throw new Error(`Unknown tool: ${name}`);
}

function handleMessage(msg) {
  const { id, method, params } = msg;

  if (method === "initialize") {
    sendResult(id, {
      protocolVersion:
        (params && params.protocolVersion) || "2025-06-18",
      capabilities: { tools: { listChanged: false } },
      serverInfo: SERVER_INFO,
    });
  } else if (method === "tools/list") {
    sendResult(id, { tools: TOOLS });
  } else if (method === "tools/call") {
    const { name, arguments: args } = params || {};
    handleToolCall(name, args)
      .then((result) => sendResult(id, result))
      .catch((err) =>
        sendResult(id, {
          content: [
            { type: "text", text: err && err.message ? err.message : String(err) },
          ],
          isError: true,
        })
      );
  } else if (method === "ping") {
    sendResult(id, {});
  } else if (
    method === "notifications/initialized" ||
    method === "notifications/cancelled" ||
    method === "notifications/roots/list_changed" ||
    method === "notifications/tools/list_changed"
  ) {
    // notifications carry no id - never reply
  } else if (id !== undefined) {
    sendError(id, -32601, `Method not found: ${method}`);
  }
}

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false,
});

rl.on("line", (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (err) {
    return; // ignore malformed input
  }
  handleMessage(msg);
});

rl.on("close", () => process.exit(0));

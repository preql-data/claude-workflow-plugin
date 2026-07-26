#!/usr/bin/env node
/*
 * stub-codex-mcp.js — a RECORDING stub of the Codex MCP server for offline
 * component tests (v4.0.0 Phase V2 / claude-workflow-plugin-1vq.1).
 *
 * It speaks REAL line-delimited JSON-RPC over stdio and enforces the REAL
 * inputSchema verified against the installed codex-cli 0.145.0 server
 * (probed offline via initialize+tools/list — see the schema-probe bd
 * comment). It NEVER contacts OpenAI: tool-call responses are canned text
 * supplied by the test via env. Every parsed request is appended to
 * STUB_LOG so specs can assert on exactly what the driver sent.
 *
 * Env knobs:
 *   STUB_LOG              append-file for one JSON line per received request
 *   STUB_MODE            ok (default) | hang | crash | no-codex-tool
 *                          hang         — read but never answer (timeout probe)
 *                          crash        — exit(1) immediately (crash probe)
 *                          no-codex-tool— tools/list omits the `codex` tool
 *   STUB_CODEX_FIRST_TEXT text returned as the codex tool-call final message
 *   STUB_CODEX_REPLY_TEXT text returned as the codex-reply final message
 *   STUB_CODEX_SLEEP_MS   delay before answering a codex tool-call (timeout)
 *   STUB_THREAD_ID        threadId echoed in structuredContent (default t-stub)
 *
 * The REAL codex tool inputSchema (additionalProperties:false, required
 * ["prompt"]) is enforced: an unknown argument or a missing prompt yields a
 * tool error result, so a driver that sends a malformed call is caught.
 */
"use strict";

const MODE = process.env.STUB_MODE || "ok";
if (MODE === "crash") {
  process.exit(1);
}

const fs = require("fs");
const LOG = process.env.STUB_LOG || "";
const THREAD_ID = process.env.STUB_THREAD_ID || "t-stub";
const FIRST_TEXT =
  process.env.STUB_CODEX_FIRST_TEXT !== undefined
    ? process.env.STUB_CODEX_FIRST_TEXT
    : '{"ok":true}';
const REPLY_TEXT =
  process.env.STUB_CODEX_REPLY_TEXT !== undefined
    ? process.env.STUB_CODEX_REPLY_TEXT
    : FIRST_TEXT;
const SLEEP_MS = parseInt(process.env.STUB_CODEX_SLEEP_MS || "0", 10) || 0;

// The codex tool's REAL allowed argument set (additionalProperties:false).
const CODEX_PROPS = new Set([
  "approval-policy",
  "base-instructions",
  "compact-prompt",
  "config",
  "cwd",
  "developer-instructions",
  "model",
  "prompt",
  "sandbox",
]);
const SANDBOX_ENUM = new Set(["read-only", "workspace-write", "danger-full-access"]);

function logReq(obj) {
  if (!LOG) return;
  try {
    fs.appendFileSync(LOG, JSON.stringify(obj) + "\n");
  } catch (_e) {
    /* best-effort */
  }
}

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

// The REAL tool descriptors (inputSchema trimmed to the load-bearing shape).
function toolsList() {
  const codex = {
    name: "codex",
    description: "Run a Codex session.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["prompt"],
      properties: {
        prompt: { type: "string" },
        sandbox: { type: "string", enum: Array.from(SANDBOX_ENUM) },
        cwd: { type: "string" },
        model: { type: "string" },
        "approval-policy": { type: "string" },
        "base-instructions": { type: "string" },
        "compact-prompt": { type: "string" },
        config: { type: "object" },
        "developer-instructions": { type: "string" },
      },
    },
  };
  const codexReply = {
    name: "codex-reply",
    description: "Continue a Codex conversation.",
    inputSchema: {
      type: "object",
      required: ["prompt"],
      properties: {
        prompt: { type: "string" },
        threadId: { type: "string" },
        conversationId: { type: "string" },
      },
    },
  };
  if (MODE === "no-codex-tool") {
    // Advertise a lookalike that is NOT literally named `codex`.
    return [{ name: "echo", description: "not codex", inputSchema: { type: "object" } }, codexReply];
  }
  return [codex, codexReply];
}

function toolResult(text) {
  return {
    content: [{ type: "text", text: text }],
    structuredContent: { threadId: THREAD_ID, content: text },
  };
}

function toolError(message) {
  return { content: [{ type: "text", text: message }], isError: true };
}

function handle(msg) {
  logReq(msg);
  const id = msg.id;
  const method = msg.method;

  if (method === "initialize") {
    send({
      jsonrpc: "2.0",
      id: id,
      result: {
        protocolVersion: "2024-11-05",
        capabilities: { tools: { listChanged: true } },
        serverInfo: { name: "stub-codex-mcp-server", version: "0.145.0-stub" },
      },
    });
    return;
  }
  if (method === "notifications/initialized") {
    return; // notification: no response
  }
  if (method === "tools/list") {
    send({ jsonrpc: "2.0", id: id, result: { tools: toolsList() } });
    return;
  }
  if (method === "tools/call") {
    const params = msg.params || {};
    const name = params.name;
    const args = params.arguments || {};

    if (name === "codex") {
      // Enforce the REAL schema: prompt required, no unknown props, sandbox enum.
      if (typeof args.prompt !== "string" || args.prompt.length === 0) {
        send({ jsonrpc: "2.0", id: id, result: toolError("schema violation: missing required 'prompt'") });
        return;
      }
      const unknown = Object.keys(args).filter((k) => !CODEX_PROPS.has(k));
      if (unknown.length > 0) {
        send({ jsonrpc: "2.0", id: id, result: toolError("schema violation: unknown argument(s): " + unknown.join(",")) });
        return;
      }
      if (args.sandbox !== undefined && !SANDBOX_ENUM.has(args.sandbox)) {
        send({ jsonrpc: "2.0", id: id, result: toolError("schema violation: sandbox not in enum: " + args.sandbox) });
        return;
      }
      const emit = () => send({ jsonrpc: "2.0", id: id, result: toolResult(FIRST_TEXT) });
      if (SLEEP_MS > 0) {
        setTimeout(emit, SLEEP_MS);
      } else {
        emit();
      }
      return;
    }
    if (name === "codex-reply") {
      if (typeof args.prompt !== "string" || args.prompt.length === 0) {
        send({ jsonrpc: "2.0", id: id, result: toolError("schema violation: missing required 'prompt'") });
        return;
      }
      if (typeof args.threadId !== "string" && typeof args.conversationId !== "string") {
        send({ jsonrpc: "2.0", id: id, result: toolError("schema violation: missing threadId/conversationId") });
        return;
      }
      send({ jsonrpc: "2.0", id: id, result: toolResult(REPLY_TEXT) });
      return;
    }
    send({ jsonrpc: "2.0", id: id, result: toolError("unknown tool: " + name) });
    return;
  }
  // Unknown method with an id -> minimal error frame.
  if (id !== undefined && id !== null) {
    send({ jsonrpc: "2.0", id: id, error: { code: -32601, message: "method not found: " + method } });
  }
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  if (MODE === "hang") {
    // Consume input but never answer — the driver must hit its timeout.
    return;
  }
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl);
    buf = buf.slice(nl + 1);
    const trimmed = line.trim();
    if (!trimmed) continue;
    let msg;
    try {
      msg = JSON.parse(trimmed);
    } catch (_e) {
      continue;
    }
    handle(msg);
  }
});
process.stdin.on("end", () => process.exit(0));

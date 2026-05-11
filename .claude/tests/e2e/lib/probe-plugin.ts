/**
 * probe-plugin.ts — Live SDK plugin-loader probe.
 *
 * Sends the smallest possible query() against the SDK with our plugin loaded
 * (`plugins: [{ type: "local", path: <pluginRoot> }]`), reads the very first
 * `system/init` event, prints `pluginErrors` and `pluginsLoaded`, and exits.
 *
 * Used as the live counterpart to `validate-plugin-manifest.ts` (which is a
 * static zod replica). The SDK's CSH() schema is the authoritative validator;
 * if our static check passes but the SDK still rejects the manifest, this
 * probe surfaces that gap quickly without paying for a full happy-path run.
 *
 * Costs ~1 turn worth of tokens — used only when iterating on manifest shape.
 *
 * Usage:
 *   npx tsx lib/probe-plugin.ts
 *   ANTHROPIC_API_KEY=... npx tsx lib/probe-plugin.ts
 *
 * Exits 0 iff `pluginErrors` is empty.
 */
import path from "node:path";
import { fileURLToPath } from "node:url";

import { findPluginRoot } from "./runFixture.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function main(): Promise<number> {
  const pluginRoot = findPluginRoot(__dirname);

  type SDKQueryFn = (opts: unknown) => AsyncIterable<unknown>;
  let queryFn: SDKQueryFn;
  try {
    const sdk = (await import("@anthropic-ai/claude-agent-sdk")) as unknown as {
      query?: SDKQueryFn;
    };
    if (typeof sdk.query !== "function") {
      throw new Error("SDK exported no query() function");
    }
    queryFn = sdk.query;
  } catch (err) {
    process.stderr.write(
      `probe-plugin: failed to import SDK. Did you 'npm install' in tests/e2e?\n  ${(err as Error).message}\n`,
    );
    return 2;
  }

  process.stdout.write(`probe-plugin: pluginRoot=${pluginRoot}\n`);

  const opts = {
    // Minimal prompt; we don't intend the model to do anything useful — we
    // just want to hit the init phase so the SDK reports plugin load status.
    prompt: "exit",
    options: {
      cwd: pluginRoot,
      settingSources: ["project"],
      plugins: [{ type: "local", path: pluginRoot }],
      permissionMode: "bypassPermissions",
      allowDangerouslySkipPermissions: true,
      maxTurns: 1,
    },
  };

  const iterator = queryFn(opts);
  let initSeen = false;
  let pluginErrors: unknown[] = [];
  let pluginsLoaded: unknown[] = [];
  let agents: unknown[] = [];
  let commands: unknown[] = [];
  // Collect all message types so we can inspect any plugin_install /
  // plugin_load_failed surface that the SDK adds in future versions.
  const seenTypes = new Set<string>();

  try {
    for await (const raw of iterator) {
      const msg = raw as {
        type?: string;
        subtype?: string;
        plugins?: unknown[];
        pluginErrors?: unknown[];
        agents?: unknown[];
        slash_commands?: unknown[];
      };
      if (msg.type) seenTypes.add(`${msg.type}/${msg.subtype ?? "_"}`);
      if (msg.type === "system" && msg.subtype === "init") {
        initSeen = true;
        pluginErrors = Array.isArray(msg.pluginErrors) ? msg.pluginErrors : [];
        pluginsLoaded = Array.isArray(msg.plugins) ? msg.plugins : [];
        agents = Array.isArray(msg.agents) ? msg.agents : [];
        commands = Array.isArray(msg.slash_commands)
          ? msg.slash_commands
          : [];
        // We have what we need; let the iterator drain naturally.
      }
    }
  } catch (err) {
    process.stderr.write(`probe-plugin: iterator error: ${(err as Error).message}\n`);
  }

  if (!initSeen) {
    process.stderr.write(
      `probe-plugin: no system/init event seen. Saw types: ${[...seenTypes].join(", ")}\n`,
    );
    return 3;
  }

  process.stdout.write(
    `probe-plugin: pluginsLoaded=${JSON.stringify(pluginsLoaded)}\n`,
  );
  process.stdout.write(
    `probe-plugin: agents=${JSON.stringify(agents)}\n`,
  );
  process.stdout.write(
    `probe-plugin: commands=${JSON.stringify(commands)}\n`,
  );
  process.stdout.write(
    `probe-plugin: pluginErrors=${JSON.stringify(pluginErrors, null, 2)}\n`,
  );
  return pluginErrors.length === 0 ? 0 : 1;
}

main()
  .then((code) => process.exit(code))
  .catch((err) => {
    process.stderr.write(`probe-plugin: ${(err as Error).stack ?? err}\n`);
    process.exit(99);
  });

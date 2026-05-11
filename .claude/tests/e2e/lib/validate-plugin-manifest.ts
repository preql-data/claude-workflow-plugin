/**
 * validate-plugin-manifest.ts — Offline validator for `.claude-plugin/plugin.json`.
 *
 * The Claude Code plugin loader (CSH() inside the bundled CLI binary) runs the
 * plugin.json through a strict zod schema. When the local-plugin loader fails,
 * the SDK emits a `pluginErrors` entry like:
 *
 *   "Plugin <name> has an invalid manifest file at <path>. Validation errors:
 *    hooks: Invalid input, commands: Invalid input, agents: Invalid input,
 *    skills: Invalid input"
 *
 * That error surface is opaque (zod's union failures collapse to "Invalid
 * input"), so before live-running the harness we mirror the schema here in a
 * zod replica and fail fast at the path level.
 *
 * Schema source: extracted from the symbol `CSH` in the bundled CLI under
 * @anthropic-ai/claude-agent-sdk-darwin-arm64/claude (and platform peers). The
 * exact constraints we replicate, by field:
 *
 *   - `name` (required), kebab-case, no spaces
 *   - `agents` :: union(
 *        string starts-with "./" ends-with ".md",
 *        array of same
 *      )
 *   - `commands` :: union(
 *        string starts-with "./" (".md" file OR directory),
 *        array of same,
 *        record<name, { source?, content?, description?, ... }>
 *      )
 *   - `skills` :: union(
 *        string starts-with "./" (skill directory),
 *        array of same
 *      )
 *   - `hooks` :: union(
 *        string starts-with "./" ends-with ".json",
 *        inline hooks object,
 *        array of either
 *      )
 *   - `mcpServers` :: union(
 *        string ".json" path,
 *        record<name, McpServer>,
 *        array of either,
 *        ".mcpb"/".dxt" path or URL
 *      )
 *
 * All paths must be relative to the plugin root and must literally start with
 * "./". This is the constraint that breaks shapes like
 * `[".claude/agents/orchestrator.md", ...]` (no leading "./").
 *
 * If the SDK ever exposes its schema for direct import we should switch to it.
 * Until then this replica is the source of truth for offline validation.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { z } from "zod";

// ---- Path primitives -------------------------------------------------------

/** Path string starting with "./" — mirrors the SDK's `Td()`. */
const RelPath = z
  .string()
  .startsWith("./", 'Plugin paths must be relative and start with "./"');

/** "./...json" — mirrors SDK `UfH()`. */
const JsonRelPath = RelPath.endsWith(
  ".json",
  "JSON config paths must end with .json",
);

/** "./...md" — mirrors SDK `kI6()`. */
const MdRelPath = RelPath.endsWith(
  ".md",
  "Agent/command markdown paths must end with .md",
);

/** Either a .md file path or a directory path — mirrors SDK `VI6()`. */
const CommandPath = z.union([MdRelPath, RelPath]);

// ---- Hook config (recursive) ----------------------------------------------

/**
 * Inline hooks object shape mirrors the runtime hooks config (the same one
 * accepted in `~/.claude/settings.json`). We don't re-validate every hook
 * subfield — the SDK does that downstream — we just check the top-level shape
 * is an object mapping event names to arrays of matchers.
 */
const HookEntry = z.object({
  matcher: z.string().optional(),
  hooks: z
    .array(
      z.object({
        type: z.string(),
        command: z.string().optional(),
        timeout: z.number().optional(),
      }).passthrough(),
    )
    .optional(),
}).passthrough();

const InlineHooks = z.object({
  description: z.string().optional(),
  hooks: z.record(z.string(), z.array(HookEntry)),
});

// ---- Component fields ------------------------------------------------------

/** `agents` :: MdRelPath | array of MdRelPath. */
const AgentsField = z.union([MdRelPath, z.array(MdRelPath)]);

/**
 * `commands` :: CommandPath | array of CommandPath | record of metadata.
 * Per SDK, the metadata variant requires either `source` (file path) or
 * `content` (inline markdown), but not both.
 */
const CommandMeta = z
  .object({
    source: CommandPath.optional(),
    content: z.string().optional(),
    description: z.string().optional(),
    argumentHint: z.string().optional(),
    model: z.string().optional(),
    allowedTools: z.array(z.string()).optional(),
  })
  .refine((c) => (c.source && !c.content) || (!c.source && c.content), {
    message:
      'Command must have either "source" (file path) or "content" (inline markdown), but not both',
  });

const CommandsField = z.union([
  CommandPath,
  z.array(CommandPath),
  z.record(z.string(), CommandMeta),
]);

/** `skills` :: skill-dir path | array of same. */
const SkillsField = z.union([RelPath, z.array(RelPath)]);

/** `hooks` :: ./*.json | inline hooks object | array. */
const HooksField = z.union([
  JsonRelPath,
  InlineHooks,
  z.array(z.union([JsonRelPath, InlineHooks])),
]);

/** `mcpServers` :: very loose — accept the documented variants without
 *  reimplementing the entire MCP server schema. */
const McpServersField = z.union([
  JsonRelPath,
  z.record(z.string(), z.unknown()),
  z.array(z.unknown()),
]);

// ---- Top-level manifest ----------------------------------------------------

/** SDK `NI6()` — name required, email/url optional. */
const Author = z
  .object({
    name: z.string().min(1, "Author name cannot be empty"),
    email: z.string().optional(),
    url: z.string().optional(),
  })
  .passthrough();

export const PluginManifest = z
  .object({
    $schema: z.string().optional(),
    name: z
      .string()
      .min(1, "Plugin name cannot be empty")
      .refine((n) => !n.includes(" "), {
        message:
          'Plugin name cannot contain spaces. Use kebab-case (e.g., "my-plugin")',
      }),
    version: z.string().optional(),
    description: z.string().optional(),
    author: Author.optional(),
    homepage: z.string().optional(),
    repository: z.string().optional(),
    license: z.string().optional(),
    keywords: z.array(z.string()).optional(),
    dependencies: z.array(z.unknown()).optional(),

    agents: AgentsField.optional(),
    commands: CommandsField.optional(),
    skills: SkillsField.optional(),
    hooks: HooksField.optional(),
    mcpServers: McpServersField.optional(),
    outputStyles: SkillsField.optional(),
    lspServers: z
      .union([JsonRelPath, z.record(z.string(), z.unknown()), z.array(z.unknown())])
      .optional(),

    settings: z.record(z.string(), z.unknown()).optional(),
    userConfig: z.record(z.string(), z.unknown()).optional(),
    channels: z.array(z.unknown()).optional(),
    experimental: z.record(z.string(), z.unknown()).optional(),
  })
  .passthrough();

export type PluginManifestT = z.infer<typeof PluginManifest>;

// ---- Public API ------------------------------------------------------------

export interface ValidationResult {
  ok: boolean;
  /** Same shape as the SDK's pluginErrors entry, joined: "field.path: message". */
  errors: string[];
  /** Parsed manifest if validation succeeded; undefined otherwise. */
  data?: PluginManifestT;
}

export function validateManifest(raw: unknown): ValidationResult {
  const parsed = PluginManifest.safeParse(raw);
  if (parsed.success) return { ok: true, errors: [], data: parsed.data };
  const errors = parsed.error.issues.map((iss) =>
    iss.path.length > 0
      ? `${iss.path.join(".")}: ${iss.message}`
      : iss.message,
  );
  return { ok: false, errors };
}

export function validateManifestFile(filePath: string): ValidationResult {
  const raw = JSON.parse(readFileSync(filePath, "utf8"));
  return validateManifest(raw);
}

// ---- CLI entry -------------------------------------------------------------

const isMain =
  import.meta.url === `file://${process.argv[1]}` ||
  process.argv[1]?.endsWith("validate-plugin-manifest.ts") ||
  process.argv[1]?.endsWith("validate-plugin-manifest.js");

if (isMain) {
  const target =
    process.argv[2] ??
    path.resolve(
      path.dirname(new URL(import.meta.url).pathname),
      "..",
      "..",
      "..",
      "..",
      ".claude-plugin",
      "plugin.json",
    );
  const result = validateManifestFile(target);
  if (result.ok) {
    process.stdout.write(`OK  ${target}\n`);
    process.exit(0);
  }
  process.stderr.write(`FAIL ${target}\n`);
  for (const e of result.errors) process.stderr.write(`  - ${e}\n`);
  process.exit(1);
}

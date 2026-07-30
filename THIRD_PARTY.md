# Third-party material

This plugin is MIT-licensed (see `LICENSE`, which backs the `"license": "MIT"`
declaration in `.claude-plugin/plugin.json`). It also ships material authored by
others. Each vendored tree carries its own manifest recording the exact upstream
version, the licence, and a runnable re-vendoring procedure; this file is the
index to those manifests, not a duplicate of them.

| What | Upstream | Licence | Where it lives | Manifest of record |
| --- | --- | --- | --- | --- |
| 10 tree-sitter `.wasm` grammars used by `code-graph-mcp` | `@vscode/tree-sitter-wasm` 0.3.1, itself built from the `tree-sitter/tree-sitter-*` grammar repositories | MIT (per-grammar; MIT across the set at the vendored versions) | `.claude/mcp/code-graph-mcp/grammars/` | [`.claude/mcp/code-graph-mcp/grammars/MANIFEST.md`](.claude/mcp/code-graph-mcp/grammars/MANIFEST.md) |
| The `brainstorming` design-dialogue skill, vendored as a reference doc with ten local modifications | [`obra/superpowers`](https://github.com/obra/superpowers) at pin `3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9` | MIT, Copyright (c) 2025 Jesse Vincent — verbatim text at [`.claude/vendor/superpowers/LICENSE.upstream`](.claude/vendor/superpowers/LICENSE.upstream) | `.claude/vendor/superpowers/` | [`.claude/vendor/superpowers/MANIFEST.md`](.claude/vendor/superpowers/MANIFEST.md) |

## Reading the second row

The vendored `brainstorming/SKILL.md` is **modified**, deliberately and
substantially: ten surgical changes reconcile it with this plugin's gates, and
every one is quoted, justified against a plugin rule, and annotated in place.
A `cmp` against upstream therefore FAILS for that file by design, and PASSES for
`LICENSE.upstream`, which is byte-identical. The manifest states both
expectations explicitly so a future auditor is never left guessing which
mismatch is intentional.

It is a REFERENCE DOC read on demand by an explicit instruction in
`.claude/agents/orchestrator.md`, not a registered skill:
`.claude-plugin/plugin.json`'s `skills[]` array stays length 1, and
`.claude/scripts/tests/vendored-skills.test.sh` asserts that.

## Not vendored

Four further upstream skills (`writing-plans`, `test-driven-development`,
`receiving-code-review`, `systematic-debugging`) were read at the same pin and
HARVESTED as practices into surfaces that already exist, rather than vendored as
files. Nothing from them is committed here as text; the ideas were rewritten in
this repo's own words, into this repo's own agent prompts. The harvest ledger —
every practice, its source, whether it was adopted, merged or skipped, and where
it landed — is recorded on Beads task `claude-workflow-plugin-kfe`.

The upstream repository ships 14 skills in total. Do NOT install it from the
marketplace alongside this plugin: registration surfaces all 14 session-wide,
and 13 of them encode an execution and approval model that competes with this
one. The reasoning, with the specific collisions named, is in
`.claude/vendor/superpowers/MANIFEST.md` under "Do NOT install upstream from
the marketplace".

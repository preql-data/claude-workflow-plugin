# Vendored tree-sitter grammars

These .wasm grammars are committed to the repo so the server has zero
external runtime fetch and zero native compile. Total on-disk size:
**~9.6 MB** across 10 grammars (verified `du -ch *.wasm` 2026-06-12).

## Source

Vendored from the `@vscode/tree-sitter-wasm` npm package version
**0.3.1** (published 2026-04). VS Code's grammar build pipeline
compiles each upstream tree-sitter language with the modern
`tree-sitter-cli@^0.25.10` (Microsoft's
[`vscode-tree-sitter-wasm`](https://github.com/Microsoft/vscode-tree-sitter-wasm)
repository drives the build). The resulting `.wasm` files use the
`dylink.0` custom-section format required by
[`web-tree-sitter@^0.26`](https://github.com/tree-sitter/tree-sitter/tree/master/lib/binding_web).

The older `tree-sitter-wasms` aggregator (0.1.13, last refreshed
2025-09) produces `.wasm` files with the legacy `dylink` section name
and is incompatible with our runtime — do not vendor from it.

## Provenance (from `@vscode/tree-sitter-wasm@0.3.1`'s devDependencies)

| File                          | Size  | Upstream grammar                       | Version |
|---|---|---|---|
| `tree-sitter-typescript.wasm` | 1.3 MB | tree-sitter/tree-sitter-typescript (ts) | ^0.23.2 |
| `tree-sitter-tsx.wasm`        | 1.4 MB | tree-sitter/tree-sitter-typescript (tsx) | ^0.23.2 |
| `tree-sitter-javascript.wasm` | 402 KB | tree-sitter/tree-sitter-javascript      | ^0.25.0 |
| `tree-sitter-python.wasm`     | 447 KB | tree-sitter/tree-sitter-python          | ^0.25.0 |
| `tree-sitter-go.wasm`         | 212 KB | tree-sitter/tree-sitter-go              | ^0.25.0 |
| `tree-sitter-rust.wasm`       | 1.1 MB | tree-sitter/tree-sitter-rust            | (vscode-built; not declared in dep tree but shipped in `wasm/`) |
| `tree-sitter-java.wasm`       | 405 KB | tree-sitter/tree-sitter-java            | ^0.23.5 |
| `tree-sitter-ruby.wasm`       | 2.0 MB | tree-sitter/tree-sitter-ruby            | ^0.23.1 |
| `tree-sitter-php.wasm`        | 1.0 MB | tree-sitter/tree-sitter-php             | 0.24.2  |
| `tree-sitter-bash.wasm`       | 1.3 MB | tree-sitter/tree-sitter-bash            | ^0.25.0 |

## Re-vendoring procedure

```bash
cd .claude/mcp/code-graph-mcp
npm install --no-save @vscode/tree-sitter-wasm@latest
for lang in typescript tsx javascript python go rust java ruby php bash; do
    cp node_modules/@vscode/tree-sitter-wasm/wasm/tree-sitter-$lang.wasm grammars/
done
npm uninstall @vscode/tree-sitter-wasm   # not a runtime dep
```

Then bump this MANIFEST's `Version` column to reflect the new
`@vscode/tree-sitter-wasm` snapshot's `package.json` devDependencies
block.

## Language coverage rationale

The 10 grammars match `detect-stack.sh`'s detection set:

- TypeScript / TSX (separate grammars per upstream)
- JavaScript / JSX (`.jsx` is parsed by the JavaScript grammar)
- Python
- Go
- Rust
- Java
- Ruby
- PHP
- Bash (the plugin's own hook ecosystem; also matches `.sh` files in
  most polyglot repos)

Adding a language is a four-step change:

1. Copy the new `.wasm` into `grammars/`.
2. Add it to `LANGUAGES` in `src/lib/parser-loader.js`.
3. Map its file extensions in the same file's `EXT_TO_LANG` table.
4. Write per-language tree-sitter queries (`defs`, `calls`, `imports`)
   in `src/lib/queries.js`, then add a fixture under
   `tests/fixtures/polyglot/` and assert against it in
   `tests/indexer.test.js`.

## Verification

Any consumer can confirm a vendored file by re-running the
`npm install --no-save @vscode/tree-sitter-wasm@0.3.1` step above and
`cmp`-ing against `node_modules/@vscode/tree-sitter-wasm/wasm/*.wasm`.
We do not check in a SHA-256 ledger because the aggregator does not
publish one and a bare `cmp` is the actual identity check.

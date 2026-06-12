// parser-loader.js — vendor-wasm tree-sitter loader.
//
// One-time init of the wasm runtime (Parser.init()), one-time language
// load per grammar, cached for the process lifetime. Loading is done
// from .wasm files committed under ../../grammars/; we never fetch from
// npm at runtime, so the server works air-gapped and behind corporate
// proxies that block downloads.
//
// Public surface:
//
//   await initRuntime()             — call once before any parser work
//   await getParser(lang)           — returns a Parser preconfigured for `lang`
//   await getLanguage(lang)         — returns the Language object
//   await preloadParsers([lang])    — bulk warm the cache for known langs
//   getParserSync(lang)             — sync accessor; throws if not preloaded
//   getLanguageSync(lang)           — sync accessor; throws if not preloaded
//   detectLanguage(path)            — file extension → language id (or null)
//   LANGUAGES                       — id → grammar filename map
//
// The split into async-warm + sync-access lets the indexer's hot loop
// stay synchronous (tree-sitter operations are sync) while the wasm
// load itself is async. Callers MUST call preloadParsers (or
// individually await getParser) before invoking the sync accessors.
//
// Performance notes: tree-sitter's wasm path is ~10-30x slower than the
// native bindings (per its README) but still indexes hundreds of files
// per second on a modern laptop. The wasm overhead is the trade-off
// for zero-native-compile installs.

import { Parser, Language } from 'web-tree-sitter';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CodeGraphError } from './errors.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GRAMMARS_DIR = path.resolve(HERE, '..', '..', 'grammars');

// Language id → vendored .wasm filename. The id is the value of the
// `lang` column in the index DB; the extensions table below maps file
// suffixes to ids.
export const LANGUAGES = {
    typescript: 'tree-sitter-typescript.wasm',
    tsx:        'tree-sitter-tsx.wasm',
    javascript: 'tree-sitter-javascript.wasm',
    python:     'tree-sitter-python.wasm',
    go:         'tree-sitter-go.wasm',
    rust:       'tree-sitter-rust.wasm',
    java:       'tree-sitter-java.wasm',
    ruby:       'tree-sitter-ruby.wasm',
    php:        'tree-sitter-php.wasm',
    bash:       'tree-sitter-bash.wasm',
};

const EXT_TO_LANG = {
    '.ts':   'typescript',
    '.mts':  'typescript',
    '.cts':  'typescript',
    '.tsx':  'tsx',
    '.js':   'javascript',
    '.mjs':  'javascript',
    '.cjs':  'javascript',
    '.jsx':  'javascript',
    '.py':   'python',
    '.pyi':  'python',
    '.go':   'go',
    '.rs':   'rust',
    '.java': 'java',
    '.rb':   'ruby',
    '.rake': 'ruby',
    '.php':  'php',
    '.sh':   'bash',
    '.bash': 'bash',
};

export function detectLanguage(filePath) {
    const ext = path.extname(filePath).toLowerCase();
    return EXT_TO_LANG[ext] || null;
}

let _runtimeInitPromise = null;
const _languageCache = new Map();  // lang id -> Language
const _parserCache = new Map();    // lang id -> Parser

export async function initRuntime() {
    if (!_runtimeInitPromise) {
        _runtimeInitPromise = Parser.init().catch((err) => {
            _runtimeInitPromise = null;
            throw new CodeGraphError('tree-sitter runtime init failed', {
                hint: 'Pass --inspect when running the server to see the underlying wasm load error. Most failures here are filesystem / permission issues on the vendored .wasm files.',
                example: 'await initRuntime()',
                stderr: err && err.stack ? err.stack : String(err),
            });
        });
    }
    return _runtimeInitPromise;
}

export async function getLanguage(langId) {
    if (_languageCache.has(langId)) return _languageCache.get(langId);
    const filename = LANGUAGES[langId];
    if (!filename) {
        throw new CodeGraphError(`unsupported language: ${JSON.stringify(langId)}`, {
            hint: `Supported: ${Object.keys(LANGUAGES).join(', ')}. Add a grammar by vendoring its .wasm into grammars/ and updating LANGUAGES.`,
            example: 'detectLanguage("foo.ts") -> "typescript"',
        });
    }
    await initRuntime();
    const wasmPath = path.join(GRAMMARS_DIR, filename);
    let bytes;
    try {
        bytes = readFileSync(wasmPath);
    } catch (err) {
        throw new CodeGraphError(`grammar file missing: ${wasmPath}`, {
            hint: 'Run `npm install` in .claude/mcp/code-graph-mcp/ and verify grammars/ is checked in. See grammars/MANIFEST.md for vendoring instructions.',
            example: `[install ok] -> getLanguage("${langId}")`,
            stderr: err && err.message ? err.message : String(err),
        });
    }
    const lang = await Language.load(bytes);
    _languageCache.set(langId, lang);
    return lang;
}

export async function getParser(langId) {
    if (_parserCache.has(langId)) return _parserCache.get(langId);
    const lang = await getLanguage(langId);
    const parser = new Parser();
    parser.setLanguage(lang);
    _parserCache.set(langId, parser);
    return parser;
}

/**
 * Warm the parser cache for the listed languages. Returns when all are
 * ready. Repeated languages are deduped.
 */
export async function preloadParsers(langs) {
    const unique = [...new Set(langs)];
    await Promise.all(unique.map((l) => getParser(l)));
}

/**
 * Sync accessor for the parser cache. Throws if the parser wasn't
 * preloaded. The indexer relies on this so its transaction loop can
 * stay synchronous; the call site is preloadParsers(allLangs) before
 * entering the indexer.
 */
export function getParserSync(langId) {
    const p = _parserCache.get(langId);
    if (!p) {
        throw new CodeGraphError(`parser cache miss for ${langId}`, {
            hint: 'Call preloadParsers([lang]) before invoking sync indexer paths.',
        });
    }
    return p;
}

export function getLanguageSync(langId) {
    const l = _languageCache.get(langId);
    if (!l) {
        throw new CodeGraphError(`language cache miss for ${langId}`, {
            hint: 'Call preloadParsers([lang]) before invoking sync indexer paths.',
        });
    }
    return l;
}

/**
 * Test/teardown helper.
 */
export function _resetForTest() {
    for (const p of _parserCache.values()) {
        try { p.delete(); } catch { /* ignore */ }
    }
    _parserCache.clear();
    _languageCache.clear();
}

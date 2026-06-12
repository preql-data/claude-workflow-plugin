// walker.js — project file walker.
//
// Walks the project tree, returning every file whose extension maps to
// a supported language. We honour two skip lists:
//
//   - SKIP_DIRS: hardcoded path components we always skip (node_modules,
//     .git, build, dist, target, __pycache__, vendor) — the standard
//     noise.
//   - .gitignore patterns: respected when git is available; otherwise
//     we fall back to the hardcoded list.
//
// The walker is sync (fs.readdirSync) because it runs once at
// index-time off the hot path, and using async fs would just add
// promise overhead without parallel I/O benefit (the OS schedules
// directory reads serially anyway).

import { readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { detectLanguage } from './parser-loader.js';

// Dir basenames we always skip — generated output, package caches,
// VCS internals, editor metadata. `.claude` is NOT in this list:
// the plugin's own source lives under .claude/, and many consumers
// will have user scripts there too. We skip the specific
// `.claude/.code-graph` and `.claude/.qa-tracking` paths below
// instead.
const SKIP_DIRS = new Set([
    '.git',
    'node_modules',
    'build',
    'dist',
    'target',
    '__pycache__',
    'vendor',
    '.next',
    '.nuxt',
    '.svelte-kit',
    '.cache',
    '.beads',   // bd's SQLite shards + per-session daemon state
    '.venv',
    'venv',
    '.idea',
    '.vscode',
    '.tmp',
    'coverage',
]);

// Project-relative paths we skip explicitly. Two scoped skips lets us
// keep .claude/agents, .claude/scripts, .claude/mcp/*/src in the index
// while excluding the runtime-only state.
const SKIP_REL_PREFIXES = [
    '.claude/.code-graph',
    '.claude/.qa-tracking',
    '.claude/.model-select-meta-task',
];

const MAX_FILE_BYTES = 2 * 1024 * 1024;  // 2 MB; bigger files are probably generated

/**
 * Walk `root` recursively. Returns an array of { abs, rel, lang } for
 * every file with a recognised extension. We DO NOT use git ls-files
 * here because it would miss new untracked files the user has just
 * created — and indexing newly-added files is exactly when the user
 * needs the code-graph most. We do respect SKIP_DIRS so node_modules
 * etc. don't blow up the index.
 *
 * `opts.respectGitignore` adds an optional pre-pass: if true and the
 * cwd is a git repo, we collect `git ls-files --others
 * --exclude-standard` plus tracked files. False by default to keep
 * walks fast on huge trees.
 */
export function walkProject(root, opts = {}) {
    const respectGitignore = opts.respectGitignore === true;
    if (respectGitignore) {
        const gitFiles = tryGitListFiles(root);
        if (gitFiles) {
            return gitFiles
                .filter((rel) => !isSkippedRelPrefix(rel))
                .map((rel) => {
                    const abs = path.join(root, rel);
                    const lang = detectLanguage(rel);
                    return lang ? { abs, rel, lang } : null;
                })
                .filter(Boolean)
                .filter(({ abs }) => isFileWithinSize(abs));
        }
    }
    return walkFS(root, root);
}

function tryGitListFiles(root) {
    try {
        const tracked = execFileSync('git', ['ls-files', '-z'], {
            cwd: root,
            encoding: 'utf8',
            maxBuffer: 16 * 1024 * 1024,
            timeout: 10_000,
        }).split('\0').filter(Boolean);
        const untracked = (() => {
            try {
                return execFileSync('git', ['ls-files', '-z', '--others', '--exclude-standard'], {
                    cwd: root,
                    encoding: 'utf8',
                    maxBuffer: 16 * 1024 * 1024,
                    timeout: 10_000,
                }).split('\0').filter(Boolean);
            } catch { return []; }
        })();
        return [...tracked, ...untracked];
    } catch {
        return null;
    }
}

function isFileWithinSize(abs) {
    try {
        const s = statSync(abs);
        return s.isFile() && s.size <= MAX_FILE_BYTES;
    } catch {
        return false;
    }
}

function isSkippedRelPrefix(rel) {
    // Normalise to forward-slash form for the prefix check; on POSIX
    // path.relative already returns forward slashes, but we run on
    // Windows too via the same code.
    const norm = rel.split(path.sep).join('/');
    for (const prefix of SKIP_REL_PREFIXES) {
        if (norm === prefix || norm.startsWith(`${prefix}/`)) return true;
    }
    return false;
}

function walkFS(root, dir) {
    const out = [];
    let entries;
    try {
        entries = readdirSync(dir, { withFileTypes: true });
    } catch {
        return out;
    }
    for (const entry of entries) {
        if (SKIP_DIRS.has(entry.name)) continue;
        const abs = path.join(dir, entry.name);
        const rel = path.relative(root, abs);
        if (isSkippedRelPrefix(rel)) continue;
        if (entry.name.startsWith('.')) {
            // Hidden dirs / files that aren't whitelisted: keep going
            // if it's `.claude` (the plugin's own home) — explicit
            // SKIP_REL_PREFIXES handle the noise within. Other dotted
            // dirs (`.config`, `.local`, etc.) get pruned. Hidden files
            // are skipped entirely unless they're an extension-mapped
            // source file (rare; `.env.example` is not source).
            if (entry.isDirectory() && entry.name !== '.claude') continue;
            if (entry.isFile()) continue;
        }
        if (entry.isDirectory()) {
            out.push(...walkFS(root, abs));
        } else if (entry.isFile() || entry.isSymbolicLink()) {
            const lang = detectLanguage(rel);
            if (!lang) continue;
            if (!isFileWithinSize(abs)) continue;
            out.push({ abs, rel, lang });
        }
    }
    return out;
}

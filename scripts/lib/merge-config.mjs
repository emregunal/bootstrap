#!/usr/bin/env node
// merge-config.mjs — surgical editor for the OpenCode global config.
//
// The rule this file exists to enforce: bootstrap only ever touches keys it
// declares ownership of. Every other key in the user's config — providers,
// models, agents, theme, keybinds — is parsed and written back untouched.
//
//   apply  --config F --mcp M --state S [--instructions P] [--servers a,b]
//   remove --config F --state S
//   read   --config F
//
// Ownership is recorded in the state file so `remove` can undo precisely what
// `apply` did, and nothing else.

import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const cmd = args.shift();
const opt = {};
for (let i = 0; i < args.length; i += 2) opt[args[i].replace(/^--/, "")] = args[i + 1];

const fatal = (m) => { console.error(m); process.exit(1); };

// --- JSONC ----------------------------------------------------------------
// OpenCode accepts .jsonc, so the user's file may legitimately contain
// comments. We strip them for parsing and report whether any were present:
// the caller warns the user, because a rewrite cannot preserve them.
function stripComments(src) {
  let out = "", inStr = false, esc = false, line = false, block = false, found = false;
  for (let i = 0; i < src.length; i++) {
    const c = src[i], n = src[i + 1];
    if (line) { if (c === "\n") { line = false; out += c; } continue; }
    if (block) { if (c === "*" && n === "/") { block = false; i++; } continue; }
    if (inStr) {
      out += c;
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') { inStr = true; out += c; continue; }
    if (c === "/" && n === "/") { line = true; found = true; i++; continue; }
    if (c === "/" && n === "*") { block = true; found = true; i++; continue; }
    out += c;
  }
  // Trailing commas are legal in JSONC but not in JSON.parse.
  return { text: out.replace(/,(\s*[}\]])/g, "$1"), hadComments: found };
}

function readJson(file, fallback) {
  if (!fs.existsSync(file)) return { data: fallback, hadComments: false };
  const raw = fs.readFileSync(file, "utf8").trim();
  if (!raw) return { data: fallback, hadComments: false };
  const { text, hadComments } = stripComments(raw);
  try {
    return { data: JSON.parse(text), hadComments };
  } catch (e) {
    fatal(`Cannot parse ${file}: ${e.message}`);
  }
}

function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
}

// `{env:VAR}` placeholders are left for OpenCode to resolve at runtime, which
// is what secrets want. `{install:VAR}` is resolved here instead, so values
// that are merely machine-specific (paths, ports) are baked in and do not
// depend on the shell environment OpenCode happens to launch with.
function resolveInstallVars(value) {
  if (typeof value === "string") {
    return value.replace(/\{install:([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, v) => process.env[v] ?? "");
  }
  if (Array.isArray(value)) return value.map(resolveInstallVars);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, resolveInstallVars(v)]));
  }
  return value;
}

// --- commands -------------------------------------------------------------
if (cmd === "read") {
  const { data } = readJson(opt.config, {});
  process.stdout.write(JSON.stringify(data, null, 2) + "\n");
  process.exit(0);
}

if (cmd === "apply") {
  if (!opt.config || !opt.mcp || !opt.state) fatal("apply: --config, --mcp and --state are required");

  const { data: cfg, hadComments } = readJson(opt.config, {});
  const { data: manifest } = readJson(opt.mcp, { servers: {} });
  const { data: state } = readJson(opt.state, {});

  // An explicit --servers "" means "manage no servers this run" (install-config
  // only touches instructions). Omitting the flag entirely means "all of them".
  const manageMcp = opt.servers !== undefined;
  const wanted = manageMcp
    ? opt.servers.split(",").map((s) => s.trim()).filter(Boolean)
    : Object.keys(manifest.servers || {});

  if (!cfg.$schema) cfg.$schema = "https://opencode.ai/config.json";

  // --- mcp ---------------------------------------------------------------
  const applied = [];
  const missingEnv = [];
  if (wanted.length) {
    cfg.mcp = cfg.mcp && typeof cfg.mcp === "object" ? cfg.mcp : {};
    for (const name of wanted) {
      const entry = (manifest.servers || {})[name];
      if (!entry) { console.error(`unknown-server:${name}`); continue; }
      const previouslyOurs = (state.mcp || []).includes(name);
      // A server the user configured themselves is theirs. We do not silently
      // rewrite it, and it must not enter `applied` either: `applied` becomes
      // state.mcp, so recording it would make the next run see previouslyOurs
      // and overwrite the very entry this branch exists to protect — and would
      // make `remove` delete it on uninstall. Ownership never transfers.
      if (cfg.mcp[name] && !previouslyOurs) { console.error(`user-owned:${name}`); continue; }

      const server = resolveInstallVars(entry.config);
      // requiresEnv: without the key the server fails on every startup, so it
      // is written disabled rather than left to error. Supplying the key and
      // re-syncing enables it again.
      // optionalEnv: the server works without the key (lower rate limits, or
      // anonymous access), so it stays enabled and only warns.
      const missing = (entry.requiresEnv || []).filter((v) => !process.env[v]);
      const soft = (entry.optionalEnv || []).filter((v) => !process.env[v]);
      if (missing.length) {
        server.enabled = false;
        for (const v of missing) missingEnv.push(`${name}:${v}:required`);
      }
      for (const v of soft) missingEnv.push(`${name}:${v}:optional`);
      cfg.mcp[name] = server;
      applied.push(name);
    }
    // Servers we used to manage but that left the manifest get cleaned up.
    for (const stale of (state.mcp || [])) {
      if (!wanted.includes(stale) && cfg.mcp[stale]) { delete cfg.mcp[stale]; console.error(`removed-stale:${stale}`); }
    }
    if (!Object.keys(cfg.mcp).length) delete cfg.mcp;
  }

  // --- instructions ------------------------------------------------------
  // Registered as an absolute path so OpenCode merges our rules file in
  // alongside whatever AGENTS.md the user already has.
  if (opt.instructions) {
    const list = Array.isArray(cfg.instructions) ? cfg.instructions.slice() : [];
    const prev = state.instructions;
    const cleaned = list.filter((p) => p !== prev && p !== opt.instructions);
    cleaned.push(opt.instructions);
    cfg.instructions = cleaned;
    state.instructions = opt.instructions;
  }

  // Leave the recorded ownership alone on a run that was not managing MCP,
  // otherwise uninstall would lose track of what it needs to remove.
  if (wanted.length) state.mcp = applied;
  state.configFile = opt.config;
  state.updatedAt = new Date().toISOString();

  writeJson(opt.config, cfg);
  writeJson(opt.state, state);

  if (hadComments) console.error("comments-dropped:1");
  for (const m of missingEnv) console.error(`missing-env:${m}`);
  if (wanted.length) console.error(`applied:${applied.join(",")}`);
  process.exit(0);
}

if (cmd === "remove") {
  if (!opt.config || !opt.state) fatal("remove: --config and --state are required");
  if (!fs.existsSync(opt.state)) { console.error("no-state"); process.exit(0); }

  const { data: cfg } = readJson(opt.config, {});
  const { data: state } = readJson(opt.state, {});

  for (const name of state.mcp || []) {
    if (cfg.mcp && cfg.mcp[name]) { delete cfg.mcp[name]; console.error(`removed:${name}`); }
  }
  if (cfg.mcp && !Object.keys(cfg.mcp).length) delete cfg.mcp;

  if (state.instructions && Array.isArray(cfg.instructions)) {
    cfg.instructions = cfg.instructions.filter((p) => p !== state.instructions);
    if (!cfg.instructions.length) delete cfg.instructions;
  }

  writeJson(opt.config, cfg);
  process.exit(0);
}

fatal(`unknown command: ${cmd}`);

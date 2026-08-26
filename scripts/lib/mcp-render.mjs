#!/usr/bin/env node
// mcp-render.mjs — translates the one MCP manifest into each agent's dialect.
//
// mcp/mcps.json is written in OpenCode's schema because that is the richest of
// the three. Claude Code and Codex want different key names, a split
// command/args pair, and TOML in Codex's case. Rather than maintain three
// manifests that drift apart, the differences live here.
//
//   list      --manifest M
//   status    --manifest M --server NAME     -> ok | missing:VAR | optional:VAR
//   render    --manifest M --target claude --server NAME
//   render    --manifest M --target codex             (whole [mcp_servers] block)
//
// Placeholder policy:
//   {install:VAR}  always resolved here, on every target.
//   {env:VAR}      left intact for OpenCode, which resolves it at runtime from
//                  its own process environment — the secret never lands in a
//                  file. Claude Code and Codex have no equivalent, so for those
//                  targets it is resolved at install time and the caller warns
//                  that a credential is being written to a local config file.

import fs from "node:fs";

const args = process.argv.slice(2);
const cmd = args.shift();
const opt = {};
for (let i = 0; i < args.length; i += 2) opt[args[i].replace(/^--/, "")] = args[i + 1];

const fatal = (m) => { console.error(m); process.exit(1); };
if (!opt.manifest) fatal("--manifest is required");

let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(opt.manifest, "utf8"));
} catch (e) {
  fatal(`cannot parse ${opt.manifest}: ${e.message}`);
}
const servers = manifest.servers || {};

const entryOf = (name) => {
  const e = servers[name];
  if (!e) fatal(`unknown server: ${name}`);
  return e;
};

// --- placeholders ---------------------------------------------------------
function substitute(value, resolveEnv) {
  if (typeof value === "string") {
    let out = value.replace(/\{install:([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, v) => process.env[v] ?? "");
    if (resolveEnv) out = out.replace(/\{env:([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, v) => process.env[v] ?? "");
    return out;
  }
  if (Array.isArray(value)) return value.map((v) => substitute(v, resolveEnv));
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, substitute(v, resolveEnv)]));
  }
  return value;
}

// A header whose placeholder resolved to nothing is worse than no header at
// all: `Authorization: Bearer ` is a malformed credential, where omitting the
// header entirely lets the server fall back to anonymous access. So a header
// is dropped rather than emptied. Decided from the RAW value, because the
// resolved one no longer shows which variable was missing.
function usableHeaders(rawHeaders, resolvedHeaders) {
  if (!rawHeaders || !resolvedHeaders) return undefined;
  const out = {};
  for (const [k, raw] of Object.entries(rawHeaders)) {
    const vars = String(raw).match(/\{(?:env|install):[A-Za-z_][A-Za-z0-9_]*\}/g) || [];
    const unset = vars.some((p) => !process.env[p.replace(/^\{(?:env|install):/, "").replace(/\}$/, "")]);
    if (unset) continue;
    out[k] = resolvedHeaders[k];
  }
  return Object.keys(out).length ? out : undefined;
}

// --- commands -------------------------------------------------------------
if (cmd === "list") {
  process.stdout.write(Object.keys(servers).join("\n") + (Object.keys(servers).length ? "\n" : ""));
  process.exit(0);
}

// Reports what a server needs from the environment, so shell callers can decide
// whether to install it, disable it, or skip it — without parsing JSON.
if (cmd === "status") {
  const e = entryOf(opt.server);
  const missing = (e.requiresEnv || []).filter((v) => !process.env[v]);
  const soft = (e.optionalEnv || []).filter((v) => !process.env[v]);
  // One line, always: every shell caller does `status="$(... status ...)"` and
  // then `${status#missing:}`, which mangles a multi-line answer. When more
  // than one variable is absent, naming the first is enough to act on.
  if (missing.length) process.stdout.write(`missing:${missing[0]}\n`);
  else if (soft.length) process.stdout.write(`optional:${soft[0]}\n`);
  else process.stdout.write("ok\n");
  process.exit(0);
}

if (cmd === "render") {
  const target = opt.target;

  // ---- Claude Code: one JSON object per server, fed to `claude mcp add-json`
  if (target === "claude") {
    const e = entryOf(opt.server);
    const c = substitute(e.config, true);
    let out;
    if (c.type === "remote" || c.type === "http" || c.type === "sse") {
      out = { type: c.type === "remote" ? "http" : c.type, url: c.url };
      const headers = usableHeaders(e.config.headers, c.headers);
      if (headers) out.headers = headers;
    } else {
      // OpenCode keeps argv as a single array; Claude Code wants it split.
      const argv = Array.isArray(c.command) ? c.command.slice() : [String(c.command)];
      out = { type: "stdio", command: argv.shift(), args: argv };
      if (c.environment && Object.keys(c.environment).length) out.env = c.environment;
    }
    process.stdout.write(JSON.stringify(out) + "\n");
    process.exit(0);
  }

  // ---- Codex: a TOML fragment for every requested server at once ----------
  if (target === "codex") {
    const wanted = (opt.servers || Object.keys(servers).join(",")).split(",").map((s) => s.trim()).filter(Boolean);
    const tomlString = (s) => JSON.stringify(String(s)); // TOML basic strings match JSON's escaping
    const lines = [];
    for (const name of wanted) {
      const e = servers[name];
      if (!e) continue;
      const c = substitute(e.config, true);
      lines.push(`[mcp_servers.${name}]`);
      if (c.type === "remote" || c.type === "http" || c.type === "sse") {
        lines.push(`type = ${tomlString(c.type === "remote" ? "http" : c.type)}`);
        lines.push(`url = ${tomlString(c.url)}`);
        const headers = usableHeaders(e.config.headers, c.headers);
        if (headers) {
          lines.push("");
          lines.push(`[mcp_servers.${name}.http_headers]`);
          for (const [k, v] of Object.entries(headers)) lines.push(`${k} = ${tomlString(v)}`);
        }
      } else {
        const argv = Array.isArray(c.command) ? c.command.slice() : [String(c.command)];
        lines.push(`command = ${tomlString(argv.shift())}`);
        if (argv.length) lines.push(`args = [${argv.map(tomlString).join(", ")}]`);
        if (c.environment && Object.keys(c.environment).length) {
          lines.push("");
          lines.push(`[mcp_servers.${name}.env]`);
          for (const [k, v] of Object.entries(c.environment)) lines.push(`${k} = ${tomlString(v)}`);
        }
      }
      lines.push("");
    }
    process.stdout.write(lines.join("\n"));
    process.exit(0);
  }

  fatal(`unknown target: ${target}`);
}

fatal(`unknown command: ${cmd}`);

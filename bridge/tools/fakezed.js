// Drives bridge.js the way Zed does, for testing without the editor.
//
//   node tools/fakezed.js <project dir> <file to open> [checks.json]
//
// Environment: SERVER_JS (required, path to haxe-language-server's server.js),
// BRIDGE_JS (default: bin/bridge.js next to this folder), SETTINGS (JSON for `project`).
// checks.json is a list of {"method", "marker", "offset", "expect"?: [labels]} where the request
// is made at the position of `marker` + `offset` in the opened file.
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const [projectDir, probeFile, checksFile] = process.argv.slice(2);
const bridgeJs = process.env.BRIDGE_JS || path.join(__dirname, "..", "bin", "bridge.js");
const settings = JSON.parse(process.env.SETTINGS || "{}");
const checks = checksFile ? JSON.parse(fs.readFileSync(checksFile, "utf8")) : [];

const child = spawn(process.execPath, [bridgeJs, "--server", process.env.SERVER_JS], { cwd: projectDir });
child.stderr.on("data", (d) => {
  for (const line of d.toString().split("\n")) if (line.includes("[haxe-zed]") || (process.env.SHOW_STDERR && line.trim())) console.log("  " + line.trim());
});

let buffer = Buffer.alloc(0);
let nextId = 1;
const pending = new Map();
let progressEnded = 0;
const notices = [];
const originals = {};
let version = 1;

function send(message) {
  message.jsonrpc = "2.0";
  const body = Buffer.from(JSON.stringify(message));
  child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
  child.stdin.write(body);
}
const request = (method, params) => {
  const id = nextId++;
  send({ id, method, params });
  return new Promise((resolve) => pending.set(id, resolve));
};
const notify = (method, params) => send({ method, params });

child.stdout.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  for (;;) {
    const end = buffer.indexOf("\r\n\r\n");
    if (end < 0) return;
    const length = parseInt(/Content-Length: (\d+)/i.exec(buffer.toString("ascii", 0, end))[1]);
    if (buffer.length < end + 4 + length) return;
    const message = JSON.parse(buffer.toString("utf8", end + 4, end + 4 + length));
    buffer = buffer.slice(end + 4 + length);
    if (message.id !== undefined && message.method === undefined) {
      pending.get(message.id)?.(message);
      pending.delete(message.id);
    } else if (message.id !== undefined) {
      if (process.env.SHOW_REGISTRATIONS && message.method === "client/registerCapability") {
        for (registration of message.params.registrations) {
          if (registration.method === "workspace/executeCommand") console.log("  commands registered: " + registration.registerOptions.commands.join(" | "));
        }
      }
      send({ id: message.id, result: message.method === "workspace/configuration" ? message.params.items.map(() => ({})) : null });
    } else if (message.method === "$/progress" && message.params.value.kind === "end") {
      progressEnded++;
    } else if (message.method === "window/showMessage") {
      notices.push(message.params.message);
    }
  }
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function positionOf(text, marker, offset) {
  const before = text.slice(0, text.indexOf(marker) + offset).split("\n");
  return { line: before.length - 1, character: before[before.length - 1].length };
}

(async () => {
  const rootUri = pathToFileURL(projectDir).href;
  const started = Date.now();
  await request("initialize", {
    processId: process.pid,
    rootUri,
    initializationOptions: { project: settings, ...JSON.parse(process.env.INIT_OPTIONS || "{}") },
    capabilities: {
      workspace: { configuration: true, didChangeWatchedFiles: { dynamicRegistration: true }, symbol: { dynamicRegistration: true }, executeCommand: { dynamicRegistration: true } },
      textDocument: {
        completion: { dynamicRegistration: true, completionItem: { snippetSupport: true, resolveSupport: { properties: ["documentation", "detail"] } } },
        hover: { dynamicRegistration: true, contentFormat: ["markdown"] },
        definition: { dynamicRegistration: true },
        codeAction: { resolveSupport: { properties: ["edit", "command"] } },
      },
      window: { workDoneProgress: true },
    },
  });
  notify("initialized", {});
  notify("workspace/didChangeConfiguration", { settings: { project: settings, haxe: JSON.parse(process.env.HAXE_SETTINGS || "{}") } });
  for (let i = 0; i < 1200 && progressEnded === 0; i++) await sleep(100);
  console.log(`completion cache ready after ${Date.now() - started} ms`);
  await sleep(500);

  const file = path.join(projectDir, probeFile);
  const text = fs.readFileSync(file, "utf8");
  const uri = pathToFileURL(file).href;
  notify("textDocument/didOpen", { textDocument: { uri, languageId: "haxe", version: 1, text } });
  await sleep(1000);

  for (const check of checks) {
    if (check.wait) {
      await sleep(check.wait);
      continue;
    }
    if (check.disk) {
      // Changes a file on disk, as git or another tool would, then reports it like Zed's file watcher
      // (`notify: false` to skip that). `restore: true` puts back the content from before the first change.
      const target = path.join(projectDir, check.disk);
      originals[target] ??= fs.readFileSync(target, "utf8");
      const before = fs.readFileSync(target, "utf8");
      const content = check.restore ? originals[target] : before.replace(check.find, check.replace);
      if (!check.restore && content === before) throw new Error(`disk: "${check.find}" not found in ${check.disk}`);
      fs.writeFileSync(target, content);
      if (check.notify !== false) {
        notify("workspace/didChangeWatchedFiles", { changes: [{ uri: pathToFileURL(target).href, type: 2 }] });
      }
      console.log(`disk: ${check.restore ? "restored" : "changed"} ${check.disk}${check.notify === false ? " (not reported)" : ""}`);
      await sleep(300);
      continue;
    }
    if (check.notify) {
      // A raw notification; `${uri:<relative path>}` and `${text:<relative path>}` are replaced.
      const raw = JSON.stringify(check.notifyParams)
        .replace(/\$\{uri:([^}]+)\}/g, (_, rel) => pathToFileURL(path.join(projectDir, rel)).href)
        .replace(/"\$\{text:([^}]+)\}"/g, (_, rel) => JSON.stringify(fs.readFileSync(path.join(projectDir, rel), "utf8")));
      notify(check.notify, JSON.parse(raw));
      console.log(`notify: ${check.notify}`);
      await sleep(300);
      continue;
    }
    if (check.params) {
      // A raw request, e.g. haxe/runMethod; `${file}` in params is replaced with the opened file's path.
      const params = JSON.parse(JSON.stringify(check.params).replaceAll("${file}", file));
      const before = Date.now();
      const response = await request(check.method, params);
      const result = response.error ?? response.result;
      if (check.dump) fs.writeFileSync(check.dump, JSON.stringify(result, null, 1));
      const items = result?.items ?? result?.result?.items;
      const summary = Array.isArray(items) ? `${items.length} items: ${items.slice(0, 10).map((i) => i.args?.field?.name ?? i.args?.name ?? i.kind).join(", ")}` : JSON.stringify(result).slice(0, 300);
      console.log(`${check.method} ${check.label ?? ""} [${Date.now() - before} ms]: ${summary}`);
      continue;
    }
    // An `edit` simulates typing: the buffer is replaced (unsaved) for this check, then restored.
    const current = check.edit ? text.replace(check.edit.find, check.edit.replace) : text;
    if (check.edit) {
      notify("textDocument/didChange", { textDocument: { uri, version: ++version }, contentChanges: [{ text: current }] });
      await sleep(200);
    }
    const params = { textDocument: { uri }, position: positionOf(current, check.marker, check.offset ?? 0) };
    if (check.method === "textDocument/completion") params.context = { triggerKind: check.trigger ? 2 : 1, triggerCharacter: check.trigger };
    const before = Date.now();
    const response = await request(check.method, params);
    const took = Date.now() - before;
    let summary;
    if (response.error) {
      summary = "ERROR " + JSON.stringify(response.error).slice(0, 200);
    } else if (check.method === "textDocument/completion") {
      const items = response.result?.items ?? response.result ?? [];
      const expected = (check.expect || []).map((label) => label + (items.some((i) => i.label === label) ? " ✓" : " ✗")).join(" ");
      // The order Zed shows with nothing typed yet: sortText, then label.
      const shown = [...items].sort((a, b) => (a.sortText ?? a.label).localeCompare(b.sortText ?? b.label) || a.label.localeCompare(b.label));
      const firstInternal = shown.findIndex((i) => i.label.startsWith("_"));
      if (process.env.SHOW_ITEM) {
        for (const i of items.filter((i) => i.label === process.env.SHOW_ITEM)) console.log("    item: " + JSON.stringify({ label: i.label, sortText: i.sortText, kind: i.kind, detail: i.detail }));
      }
      summary = `${items.length} items${response.result?.isIncomplete ? " (incomplete)" : ""} ${expected} | first: ${shown.slice(0, 8).map((i) => i.label).join(", ")} | first "_" item ${firstInternal < 0 ? "none" : "at #" + (firstInternal + 1)}`;
      if (check.positions) {
        // Where chosen items land in Zed's order, or "-" when the bridge left them out.
        summary += "\n    " + check.positions.map((label) => {
          const at = shown.findIndex((i) => i.label === label);
          return `${label} ${at < 0 ? "-" : "#" + (at + 1)}`;
        }).join(", ");
      }
      if (check.resolve) {
        // Like Zed does for the highlighted item: ask for its details.
        const item = items.find((i) => i.label === check.resolve);
        const resolved = item ? await request("completionItem/resolve", item) : null;
        summary += `\n    resolved "${check.resolve}": ${(resolved?.result?.documentation?.value ?? "no documentation").replace(/\n+/g, " ").slice(0, 160)}`;
      }
    } else if (check.method === "textDocument/hover") {
      summary = (response.result?.contents?.value ?? "null").replace(/\n+/g, " ").slice(0, 160);
    } else if (check.method === "textDocument/signatureHelp") {
      summary = (response.result?.signatures ?? []).map((sig) => sig.label).join(" | ") || "null";
    } else {
      summary = JSON.stringify(response.result).slice(0, 200);
    }
    console.log(`${check.edit ? "(edited) " : ""}${check.method} @ "${check.marker}" +${check.offset ?? 0} [${took} ms]: ${summary}`);
    if (check.edit) {
      notify("textDocument/didChange", { textDocument: { uri, version: ++version }, contentChanges: [{ text }] });
      await sleep(100);
    }
  }
  for (const [target, content] of Object.entries(originals)) fs.writeFileSync(target, content);
  for (const notice of notices) console.log("  notice: " + notice.slice(0, 200));

  await request("shutdown", null);
  notify("exit", null);
  setTimeout(() => process.exit(0), 300);
})();

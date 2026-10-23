// Drives bridge.js the way Zed does and prints what comes back, for exploring without the editor.
// For tests with expectations, use e2e/run.js.
//
//   node tools/fakezed.js <project dir> <file to open> [checks.json]
//
// Environment: SERVER_JS (required, haxe-language-server's server.js), BRIDGE_JS (default bin/bridge.js),
// SETTINGS (JSON for `project`), HAXE_SETTINGS (the server's `haxe` settings), INIT_OPTIONS (extra
// initializationOptions), SHOW_STDERR (print everything the bridge logs), SHOW_REGISTRATIONS (print command
// lists Zed is given), SHOW_ITEM=<label> (print that completion item).
//
// checks.json is a list of:
//   {"method", "marker", "offset"?, "edit"?: {find, replace}, "trigger"?, "expect"?: [labels], "positions"?: [labels],
//    "resolve"?: label}   a request at `marker` + `offset` in the opened file, typed into it first with `edit`
//   {"method", "params", "label"?, "dump"?: file}   a raw request; `${file}` in params is the opened file's path
//   {"notify", "notifyParams"}   a raw notification; `${uri:<path>}` and `${text:<path>}` are filled in
//   {"disk": path, "find", "replace", "notify"?: false}   a change on disk, reported like Zed's file watcher
//   {"wait": ms}
"use strict";
const fs = require("fs");
const path = require("path");
const { Client, positionOf, zedOrder, sleep } = require("../e2e/client");

const [projectDir, openFile, checksFile] = process.argv.slice(2);
const json = (name) => JSON.parse(process.env[name] || "{}");

(async () => {
  const client = new Client({
    serverJs: process.env.SERVER_JS,
    bridgeJs: process.env.BRIDGE_JS,
    projectDir,
    settings: json("SETTINGS"),
    haxeSettings: json("HAXE_SETTINGS"),
    initOptions: json("INIT_OPTIONS"),
    timeout: 120000,
  });
  client.onStderr = (line) => {
    if (line.includes("[haxe-zed]") || process.env.SHOW_STDERR) console.log("  " + line.trim());
  };
  client.onServerRequest = (message) => {
    if (process.env.SHOW_REGISTRATIONS && message.method === "client/registerCapability") {
      for (const registration of message.params.registrations) {
        if (registration.method === "workspace/executeCommand") console.log("  commands registered: " + registration.registerOptions.commands.join(" | "));
      }
    }
  };
  await client.start();
  console.log(`completion cache ready after ${client.readyAfter} ms`);
  const document = client.open(openFile);
  const file = path.join(client.projectDir, openFile);
  await sleep(1000);

  for (const check of checksFile ? JSON.parse(fs.readFileSync(checksFile, "utf8")) : []) {
    if (check.wait) {
      await sleep(check.wait);
    } else if (check.disk) {
      client.changeOnDisk(check.disk, (text) => text.replace(check.find, check.replace), check.notify !== false);
      console.log(`disk: changed ${check.disk}${check.notify === false ? " (not reported)" : ""}`);
      await sleep(300);
    } else if (check.notify) {
      const raw = JSON.stringify(check.notifyParams)
        .replace(/\$\{uri:([^}]+)\}/g, (_, rel) => client.uri(rel))
        .replace(/"\$\{text:([^}]+)\}"/g, (_, rel) => JSON.stringify(fs.readFileSync(path.join(client.projectDir, rel), "utf8")));
      client.notify(check.notify, JSON.parse(raw));
      console.log(`notify: ${check.notify}`);
      await sleep(300);
    } else if (check.params) {
      await rawRequest(client, check, file);
    } else {
      await request(client, document, check);
    }
  }
  for (const notice of client.notices) console.log("  notice: " + notice.slice(0, 200));
  await client.stop();
})();

async function rawRequest(client, check, file) {
  const params = JSON.parse(JSON.stringify(check.params).replaceAll("${file}", file));
  const before = Date.now();
  const response = await client.request(check.method, params);
  const result = response.error ?? response.result;
  if (check.dump) fs.writeFileSync(check.dump, JSON.stringify(result, null, 1));
  const items = result?.items ?? result?.result?.items;
  const summary = Array.isArray(items) ? `${items.length} items: ${items.slice(0, 10).map((i) => i.args?.field?.name ?? i.args?.name ?? i.kind).join(", ")}` : JSON.stringify(result).slice(0, 300);
  console.log(`${check.method} ${check.label ?? ""} [${Date.now() - before} ms]: ${summary}`);
}

async function request(client, document, check) {
  // An `edit` simulates typing: the buffer is replaced (unsaved) for this check, then restored.
  const text = check.edit ? document.saved.replace(check.edit.find, check.edit.replace) : document.text;
  if (check.edit) {
    client.change(document, text);
    await sleep(200);
  }
  const params = { textDocument: { uri: document.uri }, position: positionOf(text, check.marker, check.offset ?? 0) };
  if (check.method === "textDocument/completion") params.context = { triggerKind: check.trigger ? 2 : 1, triggerCharacter: check.trigger };
  const before = Date.now();
  const response = await client.request(check.method, params);
  const took = Date.now() - before;
  let summary;
  if (response.error) {
    summary = "ERROR " + JSON.stringify(response.error).slice(0, 200);
  } else if (check.method === "textDocument/completion") {
    summary = await describeCompletion(client, response.result, check);
  } else if (check.method === "textDocument/hover") {
    summary = (response.result?.contents?.value ?? "null").replace(/\n+/g, " ").slice(0, 160);
  } else if (check.method === "textDocument/signatureHelp") {
    summary = (response.result?.signatures ?? []).map((sig) => sig.label).join(" | ") || "null";
  } else {
    summary = JSON.stringify(response.result).slice(0, 200);
  }
  console.log(`${check.edit ? "(edited) " : ""}${check.method} @ "${check.marker}" +${check.offset ?? 0} [${took} ms]: ${summary}`);
  if (check.edit) {
    client.change(document, document.saved);
    await sleep(100);
  }
}

async function describeCompletion(client, result, check) {
  const items = result?.items ?? result ?? [];
  const expected = (check.expect || []).map((label) => label + (items.some((i) => i.label === label) ? " ✓" : " ✗")).join(" ");
  const shown = zedOrder(items);
  const firstInternal = shown.findIndex((i) => i.label.startsWith("_"));
  if (process.env.SHOW_ITEM) {
    for (const i of items.filter((i) => i.label === process.env.SHOW_ITEM)) console.log("    item: " + JSON.stringify({ label: i.label, sortText: i.sortText, kind: i.kind, detail: i.detail }));
  }
  let summary = `${items.length} items${result?.isIncomplete ? " (incomplete)" : ""} ${expected} | first: ${shown.slice(0, 8).map((i) => i.label).join(", ")} | first "_" item ${firstInternal < 0 ? "none" : "at #" + (firstInternal + 1)}`;
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
    const resolved = item ? await client.request("completionItem/resolve", item) : null;
    summary += `\n    resolved "${check.resolve}": ${(resolved?.result?.documentation?.value ?? "no documentation").replace(/\n+/g, " ").slice(0, 160)}`;
  }
  return summary;
}

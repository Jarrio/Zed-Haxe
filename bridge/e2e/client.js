// A stand-in for Zed: starts bridge.js (which starts haxe-language-server and Haxe) and talks LSP to it
// over stdio, the way Zed does. Used by e2e/run.js and tools/fakezed.js.
"use strict";
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The LSP position of `marker` + `offset` characters in `text`. */
function positionOf(text, marker, offset = 0) {
  const at = text.indexOf(marker);
  if (at < 0) throw new Error(`marker not found: ${JSON.stringify(marker)}`);
  const before = text.slice(0, at + offset).split("\n");
  return { line: before.length - 1, character: before[before.length - 1].length };
}

/** What Zed 1.25 announces in `initialize`, as far as the bridge and server look at it. */
const capabilities = {
  workspace: {
    configuration: true,
    didChangeWatchedFiles: { dynamicRegistration: true },
    symbol: { dynamicRegistration: true },
    executeCommand: { dynamicRegistration: true },
  },
  textDocument: {
    completion: { dynamicRegistration: true, completionItem: { snippetSupport: true, resolveSupport: { properties: ["documentation", "detail"] } } },
    hover: { dynamicRegistration: true, contentFormat: ["markdown"] },
    definition: { dynamicRegistration: true },
    signatureHelp: { dynamicRegistration: true },
    codeAction: { resolveSupport: { properties: ["edit", "command"] } },
  },
  window: { workDoneProgress: true, showDocument: { support: true } },
};

class Client {
  /**
   * @param {object} options
   * @param {string} options.serverJs haxe-language-server's server.js
   * @param {string} options.projectDir the workspace folder
   * @param {string} [options.bridgeJs] defaults to bin/bridge.js
   * @param {object} [options.settings] `project` settings
   * @param {object} [options.haxeSettings] the server's own `haxe` settings
   * @param {object} [options.initOptions] extra initializationOptions
   * @param {number} [options.timeout] milliseconds before a request counts as unanswered
   * @param {object} [options.env] extra environment variables for the bridge
   */
  constructor(options) {
    this.options = options;
    this.projectDir = path.resolve(options.projectDir);
    this.timeout = options.timeout ?? 30000;
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = Buffer.alloc(0);
    this.progressEnded = 0;
    /** Messages Zed would show: window/showMessage and window/showMessageRequest. */
    this.notices = [];
    /** client/registerCapability registrations, in order. */
    this.registrations = [];
    /** The latest diagnostics per URI. */
    this.diagnostics = new Map();
    /** Lines the bridge wrote to stderr. */
    this.stderr = [];
    this.documents = new Map();
    this.version = 1;
    this.changedOnDisk = new Map();
    /** Called with each stderr line, e.g. to print it. */
    this.onStderr = () => {};
    /** Called with each request from the server before it is answered. */
    this.onServerRequest = () => {};
  }

  /** Starts the bridge, initializes, and waits until the server's completion cache is built. */
  async start() {
    const bridgeJs = this.options.bridgeJs ?? path.join(__dirname, "..", "bin", "bridge.js");
    const env = { ...process.env, ...(this.options.env ?? {}) };
    this.child = spawn(process.execPath, [bridgeJs, "--server", this.options.serverJs], { cwd: this.projectDir, env });
    this.exited = new Promise((resolve) => this.child.on("exit", resolve));
    this.child.stderr.on("data", (data) => {
      for (const line of data.toString().split("\n")) {
        if (line.trim()) {
          this.stderr.push(line);
          this.onStderr(line);
        }
      }
    });
    this.child.stdout.on("data", (chunk) => this.receive(chunk));
    const started = Date.now();
    await this.request("initialize", {
      processId: process.pid,
      rootUri: pathToFileURL(this.projectDir).href,
      initializationOptions: { project: this.options.settings ?? {}, ...(this.options.initOptions ?? {}) },
      capabilities,
    });
    this.notify("initialized", {});
    this.notify("workspace/didChangeConfiguration", { settings: { project: this.options.settings ?? {}, haxe: this.options.haxeSettings ?? {} } });
    for (let i = 0; i < 1200 && this.progressEnded === 0; i++) await sleep(100);
    this.readyAfter = Date.now() - started;
    await sleep(300);
  }

  /** Sends shutdown and exit, puts back files changed on disk, and waits for the bridge to end. */
  async stop() {
    for (const [file, content] of this.changedOnDisk) fs.writeFileSync(file, content);
    if (this.child.exitCode === null) {
      await this.request("shutdown", null, 5000).catch(() => {});
      this.notify("exit", null);
      const timer = setTimeout(() => this.child.kill(), 3000);
      await this.exited;
      clearTimeout(timer);
    }
  }

  request(method, params, timeout = this.timeout) {
    const id = this.nextId++;
    this.send({ id, method, params });
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} got no answer within ${timeout} ms`));
      }, timeout);
      this.pending.set(id, (message) => {
        clearTimeout(timer);
        resolve(message);
      });
    });
  }

  notify(method, params) {
    this.send({ method, params });
  }

  uri(file) {
    return pathToFileURL(path.join(this.projectDir, file)).href;
  }

  /** Opens `file` (relative to the project) as Zed does when you open a tab. */
  open(file, languageId = file.endsWith(".xml") ? "xml" : "haxe") {
    const full = path.join(this.projectDir, file);
    const text = fs.readFileSync(full, "utf8");
    const document = { file, uri: this.uri(file), saved: text, text };
    this.documents.set(file, document);
    this.notify("textDocument/didOpen", { textDocument: { uri: document.uri, languageId, version: this.version++, text } });
    return document;
  }

  /** Replaces the open document's text (unsaved), as typing does. */
  change(document, text) {
    document.text = text;
    this.notify("textDocument/didChange", { textDocument: { uri: document.uri, version: this.version++ }, contentChanges: [{ text }] });
  }

  /** Writes the document to disk and reports the save. */
  save(document) {
    const full = path.join(this.projectDir, document.file);
    if (!this.changedOnDisk.has(full)) this.changedOnDisk.set(full, fs.readFileSync(full, "utf8"));
    fs.writeFileSync(full, document.text);
    this.notify("textDocument/didSave", { textDocument: { uri: document.uri } });
  }

  /** Changes `file` on disk, as git or a generator would, and reports it like Zed's file watcher. */
  changeOnDisk(file, change, report = true) {
    const full = path.join(this.projectDir, file);
    const before = fs.readFileSync(full, "utf8");
    if (!this.changedOnDisk.has(full)) this.changedOnDisk.set(full, before);
    const after = change(before);
    if (after === before) throw new Error(`the change to ${file} didn't apply`);
    fs.writeFileSync(full, after);
    if (report) this.notify("workspace/didChangeWatchedFiles", { changes: [{ uri: this.uri(file), type: 2 }] });
  }

  /** Waits until diagnostics for `uri` arrive (or `timeout` passes), and returns the latest. */
  async waitForDiagnostics(uri, timeout = 20000) {
    for (let waited = 0; waited < timeout && !this.diagnostics.has(uri); waited += 100) await sleep(100);
    return this.diagnostics.get(uri) ?? null;
  }

  send(message) {
    message.jsonrpc = "2.0";
    const body = Buffer.from(JSON.stringify(message));
    this.child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    this.child.stdin.write(body);
  }

  receive(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const end = this.buffer.indexOf("\r\n\r\n");
      if (end < 0) return;
      const length = parseInt(/Content-Length: (\d+)/i.exec(this.buffer.toString("ascii", 0, end))[1]);
      if (this.buffer.length < end + 4 + length) return;
      const message = JSON.parse(this.buffer.toString("utf8", end + 4, end + 4 + length));
      this.buffer = this.buffer.slice(end + 4 + length);
      this.handle(message);
    }
  }

  handle(message) {
    if (message.id !== undefined && message.method === undefined) {
      this.pending.get(message.id)?.(message);
      this.pending.delete(message.id);
      return;
    }
    if (message.id !== undefined) {
      this.onServerRequest(message);
      if (message.method === "client/registerCapability") this.registrations.push(...message.params.registrations);
      if (message.method === "window/showMessageRequest") this.notices.push(message.params.message);
      const result = message.method === "workspace/configuration" ? message.params.items.map(() => ({})) : null;
      this.send({ id: message.id, result });
      return;
    }
    switch (message.method) {
      case "$/progress":
        if (message.params.value.kind === "end") this.progressEnded++;
        break;
      case "window/showMessage":
        this.notices.push(message.params.message);
        break;
      case "textDocument/publishDiagnostics":
        this.diagnostics.set(message.params.uri, message.params.diagnostics);
        break;
    }
  }
}

/** Completion items in the order Zed shows them with nothing typed yet: sortText, then label. */
function zedOrder(items) {
  return [...items].sort((a, b) => (a.sortText ?? a.label).localeCompare(b.sortText ?? b.label) || a.label.localeCompare(b.label));
}

module.exports = { Client, positionOf, zedOrder, sleep };

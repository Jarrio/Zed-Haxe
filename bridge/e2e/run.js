// End-to-end tests: real bridge, real haxe-language-server, real Haxe, driven the way Zed drives them.
//
//   node e2e/run.js [suite names...] [--haxe=PATH] [--server=PATH] [--bridge=PATH] [--trace=FILE] [--verbose]
//
// Suites are e2e/suites/*.json. Projects in e2e/projects run anywhere; suites whose project starts with
// ${TEST_PROJECTS}/ need that environment variable (a folder of real projects with their libraries
// installed) and are skipped without it. --haxe runs every suite that doesn't pick its own Haxe with
// that compiler. haxe-language-server is the release src/lib.rs pins, downloaded into e2e/.server.
"use strict";
const fs = require("fs");
const https = require("https");
const os = require("os");
const path = require("path");
const { Client, positionOf, zedOrder, sleep } = require("./client");

const args = process.argv.slice(2);
const option = (name) => args.find((arg) => arg.startsWith(`--${name}=`))?.slice(name.length + 3);
const verbose = args.includes("--verbose");
const only = args.filter((arg) => !arg.startsWith("--"));

async function main() {
  // For projects whose own Haxe lookup is under test (e2e/projects/custom/tools/which-haxe.js).
  if (option("haxe")) process.env.E2E_HAXE = option("haxe");
  const serverJs = option("server") ?? process.env.SERVER_JS ?? (await pinnedServer());
  const suiteDir = path.join(__dirname, "suites");
  // Suite names pick from e2e/suites; a path to a .json file runs that suite instead.
  const files = only.some((arg) => arg.endsWith(".json")) ? only.map((file) => path.resolve(file))
    : fs.readdirSync(suiteDir).filter((file) => file.endsWith(".json")).sort().map((file) => path.join(suiteDir, file));
  const suites = files.map((file) => ({ id: path.basename(file, ".json"), file, ...JSON.parse(fs.readFileSync(file, "utf8")) }))
    .filter((suite) => only.length === 0 || only.includes(suite.id) || only.some((arg) => path.resolve(arg) === suite.file));
  let passed = 0, failed = 0, skipped = 0;
  for (const suite of suites) {
    const projectDir = projectPath(suite.project);
    if (projectDir === null || !fs.existsSync(projectDir)) {
      console.log(`- ${suite.name}: skipped (${suite.project} not found)`);
      skipped++;
      continue;
    }
    const result = await runSuite(suite, projectDir, serverJs);
    passed += result.passed;
    failed += result.failed;
  }
  console.log(`\n${passed} passed, ${failed} failed` + (skipped ? `, ${skipped} suites skipped` : ""));
  process.exitCode = failed > 0 ? 1 : 0;
}

function projectPath(project) {
  if (project.startsWith("${TEST_PROJECTS}/")) {
    const root = process.env.TEST_PROJECTS;
    return root ? path.join(root, project.slice("${TEST_PROJECTS}/".length)) : null;
  }
  return path.isAbsolute(project) ? project : path.resolve(__dirname, project);
}

async function runSuite(suite, projectDir, serverJs) {
  const settings = { tasks: false, ...(suite.settings ?? {}) };
  const haxe = option("haxe");
  if (haxe && suite.pinHaxe !== false) settings.haxePath = haxe;
  if (option("trace")) settings.traceFile = path.resolve(option("trace"));
  // A state folder of its own, so targets picked by an earlier run don't carry over.
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "haxe-zed-e2e-"));
  const client = new Client({
    serverJs,
    bridgeJs: option("bridge") && path.resolve(option("bridge")),
    projectDir,
    settings,
    haxeSettings: suite.haxeSettings,
    env: { HAXE_ZED_STATE_DIR: stateDir },
    openAtStart: suite.openAtStart,
  });
  if (verbose) client.onStderr = (line) => console.log(`    | ${line}`);
  let passed = 0, failed = 0;
  try {
    await client.start();
    const described = client.stderr.find((line) => line.includes("project: provider="));
    console.log(`${suite.name} (ready in ${client.readyAfter} ms)` + (described ? `\n    ${described.replace(/^.*project: /, "").slice(0, 160)}` : ""));
    const main = client.documents.get(suite.open) ?? client.open(suite.open);
    await sleep(1000);
    for (const step of suite.steps) {
      try {
        await runStep(client, main, step);
        console.log(`  ✓ ${step.name}`);
        passed++;
      } catch (error) {
        console.log(`  ✗ ${step.name}\n      ${String(error.message ?? error).split("\n").join("\n      ")}`);
        failed++;
      }
    }
    const internal = client.stderr.filter((line) => line.includes("internal error"));
    if (internal.length > 0) {
      console.log(`  ✗ the bridge logged internal errors\n      ${internal.slice(0, 3).join("\n      ")}`);
      failed++;
    }
  } catch (error) {
    console.log(`${suite.name}\n  ✗ could not run: ${error.message ?? error}`);
    failed++;
  } finally {
    await client.stop();
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
  return { passed, failed };
}

async function runStep(client, main, step) {
  const expect = step.expect ?? {};
  switch (step.do) {
    case "wait":
      return sleep(step.ms ?? 1000);
    case "changeOnDisk":
      client.changeOnDisk(step.file, (text) => text.replace(step.find, step.replace), step.report !== false);
      return sleep(500);
    case "editAndSave": {
      // As in the editor: the file is open, edited, then saved.
      const edited = client.documents.get(step.file) ?? client.open(step.file);
      client.change(edited, edited.text.replace(step.find, step.replace));
      client.save(edited);
      return sleep(800);
    }
    case "command":
      await answer(client, "workspace/executeCommand", { command: step.command, arguments: [] });
      return sleep(step.ms ?? 4000);
    case "notices":
      return check.contains(client.notices.join("\n"), expect.contains);
    case "log":
      return check.contains(client.stderr.join("\n"), expect.contains);
    case "diagnostics": {
      const document = documentFor(client, main, step);
      const diagnostics = await client.waitForDiagnostics(document.uri);
      if (diagnostics === null) {
        const arrived = [...client.diagnostics.keys()];
        throw new Error(`no diagnostics arrived for ${document.uri}` + (arrived.length ? `; they came for ${arrived.join(", ")}` : ""));
      }
      if (expect.atLeast !== undefined && diagnostics.length < expect.atLeast) {
        throw new Error(`expected at least ${expect.atLeast} diagnostics, got ${diagnostics.length}`);
      }
      return check.contains(diagnostics.map((d) => d.message).join("\n"), expect.contains);
    }
    case "symbols": {
      const result = await answer(client, "workspace/symbol", { query: step.query });
      return check.includes((result ?? []).map((symbol) => symbol.name), expect.includes);
    }
  }
  const document = documentFor(client, main, step);
  const text = step.edit ? document.saved.replace(step.edit.find, step.edit.replace) : document.text;
  if (step.edit) {
    if (text === document.saved) throw new Error(`edit didn't apply: ${JSON.stringify(step.edit.find)} not found`);
    client.change(document, text);
    await sleep(200);
  }
  try {
    const params = { textDocument: { uri: document.uri }, position: positionOf(text, step.at, step.offset ?? 0) };
    if (step.do === "completion") params.context = step.trigger ? { triggerKind: 2, triggerCharacter: step.trigger } : { triggerKind: 1 };
    const result = await answer(client, "textDocument/" + step.do, params);
    expectations[step.do](result, expect);
  } finally {
    if (step.edit) {
      client.change(document, document.saved);
      await sleep(100);
    }
  }
}

/** The document a step is about: `file`, opened if it isn't yet, else the suite's main one. */
function documentFor(client, main, step) {
  return step.file ? client.documents.get(step.file) ?? client.open(step.file) : main;
}

/** Sends a request and returns its result; an error response fails the step. */
async function answer(client, method, params) {
  const response = await client.request(method, params);
  if (response.error) throw new Error(`${method} failed: ${JSON.stringify(response.error).slice(0, 200)}`);
  return response.result;
}

const check = {
  contains(text, wanted) {
    for (const part of [wanted ?? []].flat()) {
      if (!text.includes(part)) throw new Error(`expected ${JSON.stringify(part)} in:\n${text.slice(0, 400)}`);
    }
  },
  includes(labels, wanted) {
    const missing = (wanted ?? []).filter((label) => !labels.includes(label));
    if (missing.length > 0) throw new Error(`missing ${missing.join(", ")}; got ${labels.slice(0, 15).join(", ")}${labels.length > 15 ? ", ..." : ""}`);
  },
};

function locations(result) {
  return [result ?? []].flat().map((location) => ({
    uri: location.targetUri ?? location.uri,
    line: (location.targetSelectionRange ?? location.targetRange ?? location.range).start.line,
  }));
}

const expectations = {
  completion(result, expect) {
    const items = result?.items ?? result ?? [];
    const labels = zedOrder(items).map((item) => item.label);
    check.includes(labels, expect.includes);
    const present = (expect.excludes ?? []).filter((label) => labels.includes(label));
    if (present.length > 0) throw new Error(`should not list ${present.join(", ")}`);
    for (const [first, second] of expect.before ?? []) {
      if (labels.indexOf(first) < 0 || labels.indexOf(second) < 0 || labels.indexOf(first) > labels.indexOf(second)) {
        throw new Error(`expected ${first} (#${labels.indexOf(first) + 1}) before ${second} (#${labels.indexOf(second) + 1})`);
      }
    }
    if (expect.incomplete !== undefined && (result?.isIncomplete === true) !== expect.incomplete) {
      throw new Error(`expected isIncomplete ${expect.incomplete}`);
    }
  },
  hover(result, expect) {
    const contents = result?.contents;
    check.contains(typeof contents === "string" ? contents : contents?.value ?? JSON.stringify(contents ?? null), expect.contains);
  },
  definition: expectLocation,
  typeDefinition: expectLocation,
  implementation: expectLocation,
  signatureHelp(result, expect) {
    check.contains((result?.signatures ?? []).map((signature) => signature.label).join("\n"), expect.contains);
  },
};

function expectLocation(result, expect) {
  const found = locations(result);
  if (expect.empty) {
    if (found.length > 0) throw new Error(`expected no location, got ${found[0].uri}:${found[0].line}`);
    return;
  }
  if (found.length === 0) throw new Error("no location");
  const hit = found.find((location) => !expect.file || location.uri.endsWith(expect.file));
  if (!hit) throw new Error(`expected ${expect.file}, got ${found.map((location) => location.uri).join(", ")}`);
  if (expect.line !== undefined && hit.line !== expect.line) throw new Error(`expected line ${expect.line}, got ${hit.line}`);
}

/** The haxe-language-server release src/lib.rs downloads, fetched once into e2e/.server. */
async function pinnedServer() {
  const shim = fs.readFileSync(path.join(__dirname, "..", "..", "src", "lib.rs"), "utf8");
  const constant = (name) => new RegExp(`const ${name}: &str = "([^"]+)"`).exec(shim)[1];
  const version = constant("SERVER_VERSION");
  const target = path.join(__dirname, ".server", version, "server.js");
  if (!fs.existsSync(target)) {
    const url = `https://github.com/${constant("SERVER_REPO")}/releases/download/server-${version}/${constant("SERVER_ASSET")}`;
    console.log(`downloading ${url}`);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, await download(url));
  }
  return target;
}

function download(url, redirects = 5) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { "User-Agent": "zed-haxe-e2e" } }, (response) => {
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location && redirects > 0) {
        response.resume();
        resolve(download(response.headers.location, redirects - 1));
      } else if (response.statusCode !== 200) {
        reject(new Error(`${url}: HTTP ${response.statusCode}`));
      } else {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.on("end", () => resolve(Buffer.concat(chunks)));
      }
    }).on("error", reject);
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

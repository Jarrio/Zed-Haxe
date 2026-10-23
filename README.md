# Haxe language support for Zed

![Screenshot of Zed editor](media/example-gruvbox.webp)

Syntax highlighting, outline and text objects come from tree-sitter.
Completion, hover, go to definition, references, rename, diagnostics,
formatting, code actions and inlay hints come from
[haxe-language-server](https://github.com/vshaxe/haxe-language-server),
the same server vshaxe uses in VS Code, unmodified.

Between Zed and the server sits a small **bridge written in Haxe** (`bridge/`).
It does the work the VS Code extensions do for vshaxe:

- finds out what kind of project you have and asks its tool for the compiler arguments
  (`lime display`, `ceramic clay hxml`, or your `.hxml`)
- picks the right Haxe: Ceramic's bundled one, the version in `.haxerc`
  (through lix or [haxe-manager](https://github.com/kLabz/haxe-manager)), or `haxe` on your PATH
- switches target or Haxe version without restarting when settings or project files change
- fills gaps between the server and Zed: Go to Type Definition, Go to Implementation,
  file watching, workspace symbols on Haxe 5, and docs for defines and metadata
  (including library docs from `meta.json`/`defines.json`)
- keeps the compiler's cache up to date when you save a file or one changes on disk (git, code
  generators), so completion in other files sees the change instead of old or empty results
- adds completion, hover and go to definition inside UI markup: HaxeUI's `@:xml` and `.xml`
  layouts, including real Haxe completion inside `onclick` handlers

## Requirements

- Haxe 4.3 or newer, unless your framework brings its own (Ceramic does)
- The libraries your project uses, installed as usual (`haxelib install`, `lix download`, ...)

## What gets detected

| Project | Found by | Display arguments from |
|---|---|---|
| Lime, OpenFL, HaxeFlixel | `project.xml`, `Project.xml`, `project.hxp`, `project.lime` | `lime display <target>` (or `haxelib run lime display`) |
| Ceramic | `ceramic.yml` | `ceramic clay hxml <target> --setup`; Haxe from `ceramic haxe` |
| Plain Haxe | any `.hxml` | the one that builds something and sees the most of the project's class paths, then the best-named one (`build.hxml`, `main`, `lsp`, ...) |
| Anything else | | `src/` (or the folder) as class path |

Project files are searched in the project folder and a few levels below it.
When a Lime or Ceramic project has several targets, Zed shows them once as buttons; your choice is remembered.
See "Tasks and switching targets" below for switching later.

## Settings

Everything is optional. Put project settings in `.zed/settings.json`, or in your user settings:

```json
{
  "lsp": {
    "haxe-language-server": {
      "settings": {
        "project": {
          "target": "html5",
          "buildType": "debug"
        },
        "haxe": {
          "inlayHints": { "variableTypes": true, "functionReturnTypes": true }
        }
      }
    }
  }
}
```

`project` is read by the bridge:

| Key | Meaning |
|---|---|
| `root` | Project folder relative to the workspace, for monorepos (`"game"`) |
| `target` | Target to use: `"html5"`/`"hl"`/... for Lime, `"web"`/`"linux"`/... for Ceramic, an hxml path for plain projects |
| `buildType` | `"debug"`, `"release"` or `"final"` |
| `provider` | Force a provider: `"lime"`, `"ceramic"`, `"hxml"`, or one of yours |
| `args` | Explicit compiler arguments, e.g. `["build.hxml"]`; skips detection |
| `haxePath` | Explicit Haxe executable; wins over everything below |
| `haxeResolvers` | Order of Haxe lookups. Default `["provider", "lix", "haxe-manager", "path"]`. Drop `"provider"` to ignore Ceramic's bundled Haxe |
| `commands` | Replace tool executables with absolute paths: `{"lime": "/opt/lime/lime", "ceramic": "/opt/ceramic/tools/ceramic"}` |
| `providers`, `resolvers` | Your own project providers and Haxe lookups, see below |
| `tasks` | `false` stops writing `.zed/tasks.json` (see below) |
| `markup` | `false` turns off completion and hover in UI markup (see below) |
| `privateMembers` | Where other classes' private members and `_`-prefixed fields go in completion lists: `"last"` (default), `"hide"`, or `"show"` to keep the compiler's order. Members of the class you are editing always stay in place |
| `traceFile` | Append every LSP message to this file, for debugging |

`haxe` holds haxe-language-server's own settings
([list](https://github.com/vshaxe/haxe-language-server/blob/master/src/haxeLanguageServer/Configuration.hx)).
Zed keeps inlay hints and code lens off until you enable them in Zed's settings too.

`server.path` points at a local build of haxe-language-server's `server.js` instead of the download.

## Adding a project provider

Most frameworks work the same way: a marker file, and a command that prints compiler arguments.
Describe yours in settings, no rebuild needed. A sketch for Kha (not tested):

```json
"project": {
  "providers": [{
    "name": "kha",
    "detect": ["khafile.js"],
    "targets": ["html5", "krom", "windows"],
    "args": {
      "command": ["node", "Kha/make", "${target}"],
      "output": { "file": "build/project-${target}.hxml" }
    },
    "displayCwd": "${projectDir}/build",
    "watch": ["khafile.js"]
  }]
}
```

- `command` can also be a list of alternatives, tried until one exists.
- `output` is `"hxml"` (stdout is hxml, the default), `{"file": ...}` (the command writes an hxml file), or `"json"`.
- Placeholders: `${workspaceRoot}`, `${projectDir}`, `${projectFile}`, `${target}`, `${buildType}`, and `${buildTypeArgs}` for the per-build-type arguments in `buildTypes`.
- A definition with the name of a built-in one replaces it.

With `"output": "json"`, the command prints
`{"args": [...], "targets": [...], "watch": [...], "haxePath": "..."}` (only `args` is required).
A framework can ship such a command itself, e.g. `haxelib run mylib ide-args`, and work without changes here.

Built-in definitions live in `bridge/providers/*.json`; a new one is a JSON file there.
Providers that need code implement `bridge.project.ProjectProvider` (see `CeramicProvider.hx`).

Haxe lookups work the same way: `"resolvers": [{"name": "mytool", "command": ["mytool", "which-haxe", "${haxercVersion}"]}]`,
then list `"mytool"` in `haxeResolvers`. The command prints the Haxe path.

Provider and lookup definitions only come from the extension and from Zed settings
(Zed asks before trusting a project's `.zed/settings.json`); the bridge doesn't read them from other files.
As with any Haxe tooling, computing completion runs the project's build tools and macros.

## Library docs (meta.json / defines.json)

Since Haxe 4.3, libraries can document their metadata and defines in JSON
(`"documentation"` in haxelib.json, or `haxe.macro.Compiler.registerMetadataDescriptionFile`).
The bridge shows those docs, with the library they come from, when you hover or complete
defines in `#if` and metadata after `@:`.

Lime, OpenFL and HaxeFlixel don't ship such files yet, so the bridge brings its own
(`bridge/docs/`): Flixel's `FLX_*` defines and the asset embedding metadata
(`@:bitmap`, `@:sound`, `@:file`, `@:image`, `@:font`).
A provider definition can add packs for other libraries with `"docs": [{"lib": "mylib", "defines": "path/to/defines.json"}]`.

## Tasks and switching targets

Zed extensions can't add their own buttons or status bar items, so this uses Zed's own pickers.

**Switching targets:** `lsp command selector: toggle` (command palette) lists a command for every
target and build type of the project, with the current ones marked:

```
Haxe: target html5 (current)
Haxe: target hl
Haxe: build type debug
Haxe: build type release (current)
Haxe: choose target
```

Picking one switches without a restart, and is remembered for the project. `project.target` and
`project.buildType` in settings set the starting point. To open the list with a key, bind
`lsp_command_selector::Toggle` in your keymap.

**Tasks:** the extension writes the project's build and run commands to `.zed/tasks.json`, so
`task: spawn` and `task: rerun` offer them (Zed sorts the list itself):

| Project | Tasks |
|---|---|
| Lime, OpenFL, HaxeFlixel | `lime: test <target>`, `lime: build <target>` for every target |
| Ceramic | `ceramic: run <target>`, `ceramic: build <target>`, with each target's backend |
| Plain Haxe | `haxe: <file>.hxml` for every hxml that builds something |

They use the build type you picked and the project's own Haxe (the one from `.haxerc` or Ceramic),
and are rewritten when targets change. The extension only rewrites a `.zed/tasks.json` it generated
(it starts with a comment saying so). If you already have one, it is left alone; deleting the comment
lines from the generated one makes it yours. `"project": { "tasks": false }` turns generation off.

Provider definitions bring their own task templates, so a provider you add in settings can too:

```json
"tasks": [{"label": "kha: run ${target}", "command": ["node", "Kha/make", "${target}", "--run"]}]
```

A template that mentions `${target}` becomes one task per target.

## UI markup (HaxeUI)

In projects using haxeui-core, the bridge understands HaxeUI layouts, both inline in Haxe files
(`@:xml('...')` and `@:xml(<window>...</window>)` on a component class) and as `.xml` files:

- tag completion for every component, including your own (from HaxeUI's `module.xml` files,
  the way HaxeUI itself finds them), with hover docs and go to definition to the class
- attribute completion from the component's public properties (with types, `true`/`false` for
  `Bool`s, and HaxeUI's `group` and `contentLayout` names), plus `on<event>` handlers for every
  HaxeUI event; go to definition on an attribute opens the property
- Haxe completion, signature help, hover and go to definition inside handlers like
  `onclick="..."`, compiled the way HaxeUI compiles them: in the class the XML belongs to,
  with `this` as the component and components with an `id` as variables

The answers come from the compiler, through the language server's connection. A component's attributes
are fetched once (about 60 to 100 ms) and kept until a Haxe file is saved; tag lists are read from source files.
Completion in ordinary Haxe code is unaffected.

`.xml` files need Zed's XML extension, which defines the XML language; this extension adds its
language server to it. Other XML files (`project.xml`, data files) are left to the XML extension.
An `.xml` layout is tied to its class through `ComponentBuilder.build("...")` / `ComponentMacros.build("...")`
in your sources; a layout loaded only at runtime still gets tags, attributes and component ids.

Other frameworks can be added as a `bridge.markup.MarkupProvider` (see `HaxeUiProvider.hx`) and
listed in `MarkupFeature.createProviders`: a provider supplies where markup lives, how tags map
to classes, and which attribute values are Haxe code. Everything else is shared.

## Development

You need Haxe, Node.js and [Rust](https://rustup.rs/).

```sh
cd bridge
haxelib newrepo
haxelib state load install.hxml
haxe build.hxml   # writes bin/bridge.js, which the Rust side embeds
haxe test.hxml    # unit tests
```

Then in Zed's Extensions panel, click `Install Dev Extension` and pick this folder.
Zed compiles the Rust part; the first time it may download its WASM toolchain (about 500 MiB).
`zed: open log` shows progress, and `dev: open language server logs` shows the bridge's
`[haxe-zed]` lines with the detected project and Haxe.

Upstream publishes no standalone releases of haxe-language-server, so the extension downloads
an unmodified build from the releases of the fork
[Jarrio/haxe-language-server](https://github.com/Jarrio/haxe-language-server)
(`SERVER_REPO` and `SERVER_VERSION` in `src/lib.rs`).
To publish a newer upstream commit, run `scripts/release-server.sh <commit>` with a Haxe 5 nightly
on your PATH and `gh` logged in, then update `SERVER_VERSION`.
To try a local build instead, set `server.path` to its `bin/server.js`.

## Known limitations

- Switching a project with a `.haxerc` from Haxe 4 to Haxe 5 needs a language server restart:
  the server can't make that switch in place.
- Code lens still uses the compiler's old XML API, which Haxe 5 removed.
- HaxeUI `<script>` blocks get no completion yet, only attribute handlers do.
- NME and Kha have no built-in provider yet; see "Adding a project provider".

## Credits

This is a fork of [Frixuu's Zed-Haxe](https://github.com/Frixuu/Zed-Haxe), but almost all of it is a rewrite.
Kept from the original:

- the language configs and tree-sitter queries in `languages/` (highlighting, outline, brackets,
  indents, folds) and the choice of grammars
- the way completion and symbol labels get syntax highlighting
- falling back to the last downloaded server when offline
- the extension id `haxe` and server name `haxe-language-server`, so existing settings keep working

Everything else is new, including the bridge, project and Haxe detection, tasks, target switching
and the markup support.

Also built on:

- [tree-sitter grammar by tong](https://github.com/tong/tree-sitter-haxe)
- [haxe-language-server by the vshaxe team](https://github.com/vshaxe/haxe-language-server), MIT-licensed

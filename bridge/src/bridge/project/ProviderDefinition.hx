package bridge.project;

import haxe.DynamicAccess;

/**
	A project provider described as data, run by `CommandProvider`.

	Built-in definitions live in `bridge/providers/*.json`; users add more under `project.providers`
	in their Zed settings. Placeholders available in commands, `cwd`, `displayCwd` and `output.file`:
	`${workspaceRoot}`, `${projectDir}`, `${projectFile}`, `${target}`, `${buildType}`.
	An argument that is exactly `${buildTypeArgs}` expands to the matching `buildTypes` entry.

	```json
	{
		"name": "lime",
		"detect": ["project.xml", "Project.xml"],
		"targets": ["html5", "hl"],
		"buildTypes": {"debug": ["-debug"], "final": ["-final"]},
		"args": {
			"command": [["lime", "display", "${target}", "${buildTypeArgs}"], ["haxelib", "run", "lime", "display", "${target}", "${buildTypeArgs}"]],
			"cwd": "${projectDir}",
			"output": "hxml"
		},
		"watch": ["project.xml", "Project.xml"]
	}
	```
**/
typedef ProviderDefinition = {
	var name:String;

	/** Default 50. Plain hxml detection uses 0, framework providers 100. **/
	var ?priority:Int;

	/** File names that mark a project of this kind, searched in the project root and two levels below. **/
	var detect:Array<String>;

	/** Fixed list of targets; the first one is the default. **/
	var ?targets:Array<String>;

	/** Command printing one target per line, used when `targets` is absent. **/
	var ?targetsCommand:CommandSpec;

	/** Extra arguments per build type, inserted where `${buildTypeArgs}` appears. **/
	var ?buildTypes:DynamicAccess<Array<String>>;

	/** Command producing the display arguments. **/
	var args:CommandSpec;

	/**
		Folder the produced arguments are relative to. Default `${projectDir}`.
		When it isn't the workspace root, `--cwd <folder>` is put in front of the arguments.
	**/
	var ?displayCwd:String;

	/** File names that trigger re-resolution when they change. Defaults to `detect`. **/
	var ?watch:Array<String>;

	/** Metadata/define documentation packs for libraries this provider uses. **/
	var ?docs:Array<DocPack>;

	/**
		Build and run commands for the editor's task list. A template whose label or command uses
		`${target}` becomes one task per target. Same placeholders as `args`; `cwd` defaults to `${projectDir}`.
	**/
	var ?tasks:Array<TaskTemplate>;
}

typedef TaskTemplate = {
	var label:String;
	var command:Array<String>;
	var ?cwd:String;
}

typedef CommandSpec = {
	/**
		The command line, executable first. Either one command (`["lime", "display"]`) or a list of
		alternatives tried in order until one exists (`[["lime", "display"], ["haxelib", "run", "lime", "display"]]`).
	**/
	var command:Array<Dynamic>;

	/** Working directory. Default `${projectDir}`. **/
	var ?cwd:String;

	/**
		How to read the result:
		- `"hxml"` (default): stdout is hxml
		- `"lines"`: one entry per stdout line (for `targetsCommand`)
		- `"json"`: stdout is `{"args": [...], "targets"?: [...], "watch"?: [...], "haxePath"?: "..."}`
		- `{"file": "build/project.hxml"}`: the command writes an hxml file, relative to `cwd`
	**/
	var ?output:Dynamic;
}

/**
	A library's metadata and define documentation, in the compiler's own JSON format
	(see `haxe.macro.Compiler.registerMetadataDescriptionFile`).
**/
typedef DocPack = {
	/**
		Library the docs belong to. The pack is used when the arguments mention it as `-lib <lib>`
		or `-D <lib>` (Lime and haxelib define one per library), or always when `lib` is omitted.
	**/
	var ?lib:String;

	/** Path to a metadata description file. Built-in packs use `builtin:<name>`. **/
	var ?metadata:String;

	/** Path to a define description file. Built-in packs use `builtin:<name>`. **/
	var ?defines:String;
}

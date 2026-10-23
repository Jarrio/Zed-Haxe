package bridge.project;

import bridge.Settings.ProjectSettings;
import bridge.project.ProviderDefinition.DocPack;
import haxe.DynamicAccess;
import js.lib.Promise;

/**
	Everything a provider may look at. Providers know nothing about LSP or Zed.
**/
typedef ProjectContext = {
	/** Folder opened in the editor. **/
	final workspaceRoot:String;

	/** `workspaceRoot` joined with `settings.root`. **/
	final projectRoot:String;

	final settings:ProjectSettings;

	/** Environment for provider commands. **/
	final env:DynamicAccess<String>;
}

/** A command for building or running the project, shown as a task in the editor. **/
typedef TaskSpec = {
	var label:String;

	/** Executable, then arguments. `haxe` and `haxelib` are replaced by the project's own Haxe. **/
	var command:Array<String>;

	var cwd:String;

	/** The target the task is for, if any (tasks for the current target are listed first). **/
	var ?target:String;
}

typedef ProviderResult = {
	/** Display arguments for the language server (`displayArguments`). **/
	var args:Array<String>;

	/** Haxe executable this project expects, e.g. the one bundled with Ceramic. **/
	var ?haxePath:String;

	/** Extra file names whose change should trigger re-resolution. **/
	var ?watch:Array<String>;

	/** Metadata/define documentation to register with the compiler. **/
	var ?docs:Array<DocPack>;
}

/**
	Detects one kind of Haxe project and computes its display arguments.

	To add a provider in Haxe, implement this interface and add it to `Registry.codeProviders`.
	Most frameworks don't need code: see `ProviderDefinition` for the JSON form.
**/
interface ProjectProvider {
	/** Unique name, used by `project.provider` and to override built-ins. **/
	var name(default, null):String;

	/** When several providers detect something, the highest priority wins. **/
	var priority(default, null):Int;

	/** Returns the project files this provider recognises under `ctx.projectRoot`, best match first. **/
	function detect(ctx:ProjectContext):Array<String>;

	/** Lists the targets a user can pick for the project file `file`. May be empty. **/
	function targets(ctx:ProjectContext, file:String):Promise<Array<String>>;

	/** Computes the display arguments for `file` and `target`. **/
	function resolve(ctx:ProjectContext, file:String, target:Null<String>):Promise<ProviderResult>;

	/** File names that trigger re-resolution when they change. **/
	function watch():Array<String>;

	/** Build and run commands for `file`'s targets, for the editor's task list. **/
	function tasks(ctx:ProjectContext, file:String, targets:Array<String>):Array<TaskSpec>;

	/** Build types the user can switch between (e.g. `debug`, `release`); empty when the provider has none. **/
	function buildTypes():Array<String>;
}

package bridge;

import bridge.project.ProviderDefinition;
import bridge.toolchain.ResolverDefinition;
import haxe.DynamicAccess;

/**
	The `project` section of the bridge settings, written by users in Zed's settings.json under
	`lsp.haxe-language-server.settings.project`.

	Every field is optional; with no settings at all the bridge detects everything itself.
**/
typedef ProjectSettings = {
	/** Folder of the Haxe project, relative to the workspace root (for monorepos). **/
	var ?root:String;

	/** Forces a provider by name (`"lime"`, `"ceramic"`, `"hxml"`, or one from `providers`). **/
	var ?provider:String;

	/** Target to use, e.g. `"html5"` for Lime, `"web"` for Ceramic, or an hxml path for plain hxml projects. **/
	var ?target:String;

	/** `"debug"`, `"release"` or `"final"`; providers decide what each means. **/
	var ?buildType:String;

	/** Explicit display arguments. Skips detection entirely. **/
	var ?args:Array<String>;

	/** Explicit Haxe executable. Wins over every toolchain resolver. **/
	var ?haxePath:String;

	/** Order of toolchain resolvers. Defaults to `["provider", "lix", "haxe-manager", "path"]`. **/
	var ?haxeResolvers:Array<String>;

	/** Extra or overriding project providers. A definition with a built-in's name replaces it. **/
	var ?providers:Array<ProviderDefinition>;

	/** Extra toolchain resolvers, referenced by name from `haxeResolvers`. **/
	var ?resolvers:Array<ResolverDefinition>;

	/** Replaces the executable of provider commands, e.g. `{"lime": "/opt/lime/lime"}`. **/
	var ?commands:DynamicAccess<String>;

	/**
		Private members and `_`-prefixed internals of other classes in completion lists:
		`"last"` (default) lists them after the rest, `"hide"` leaves them out, `"show"` keeps the compiler's order.
		Members of the class you are writing in are never affected.
	**/
	var ?privateMembers:String;

	/** Write the project's build and run tasks to `.zed/tasks.json` (only a file the extension created). Default true. **/
	var ?tasks:Bool;

	/**
		Write debug configurations for the Haxe debugger extension to `.zed/debug.json` (only a file the
		extension created), one per task it can debug. Default: the same as `tasks`.
	**/
	var ?debugConfigurations:Bool;

	/** Completion, hover and go to definition in UI markup (HaxeUI's `@:xml` and `.xml` layouts). Default true. **/
	var ?markup:Bool;

	/** Appends every LSP message passing through the bridge to this file. **/
	var ?traceFile:String;
}

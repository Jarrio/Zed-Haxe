package bridge.markup;

import js.lib.Promise;

/** A span of markup inside a document, as offsets. **/
typedef Region = {
	final start:Int;
	final end:Int;
}

typedef TagInfo = {
	/** The name to insert, e.g. `button` or `window-title`. **/
	var name:String;

	/** Full Haxe type path of the class the tag creates. **/
	var typePath:String;

	/** Text to match typing against, when other spellings should find the tag too. **/
	var ?filterText:String;
}

typedef AttributeInfo = {
	var name:String;

	/** Printed Haxe type, e.g. `Bool`. **/
	var ?type:String;

	/** Values to offer, e.g. `["true", "false"]`. **/
	var ?values:Array<String>;

	var ?doc:String;

	/** The value is Haxe code (an event handler); completion inside it comes from the compiler. **/
	var ?code:Bool;

	/** Field the attribute sets, when it differs from `name` (for hover and go to definition). **/
	var ?field:String;
}

/** The class a piece of markup is compiled into, which Haxe code inside it can see. **/
typedef HostClass = {
	final file:String;
	final className:String;
}

/** How Haxe code inside markup is compiled. **/
typedef CodeContext = {
	/** Type of `this` inside the code. **/
	final thisType:Null<String>;

	/** What `this` is renamed to before typing (HaxeUI renames it to `__this__`). **/
	final thisAlias:Null<String>;

	/** Locals visible to the code, name => type path (HaxeUI: components with an id). **/
	final locals:Map<String, String>;

	/** The class the code is compiled in, when known. **/
	final host:Null<HostClass>;
}

/** What providers can ask the compiler. Implemented over the language server's connection to Haxe. **/
interface Compiler {
	/** Absolute class paths of the current compilation, without the standard library. **/
	function classPaths():Promise<Array<String>>;

	/** Public fields of `typePath`, as Haxe display items, seen from a module of `host`. **/
	function fields(typePath:String, host:HostClass):Promise<Array<Dynamic>>;
}

/** The project a provider works in. **/
typedef MarkupProject = {
	final workspaceRoot:String;

	/** Display arguments with hxml files expanded (`Hxml.expand`). **/
	final args:Array<String>;
	final compiler:Compiler;

	/** Text of a file: the editor's copy when it is open, else the file on disk. **/
	final readFile:String->Null<String>;

	/** A class of the project to ask the compiler from when no better one is known. **/
	final defaultHost:() -> Null<HostClass>;
}

/**
	Knows one framework's markup: where it lives, which tags and attributes exist,
	and which attribute values are Haxe code.

	Markup support itself (finding the position, completion, hover, asking the compiler)
	is shared; a provider only supplies the framework's rules. See `HaxeUiProvider`.
**/
interface MarkupProvider {
	var name(default, null):String;

	/** Whether the project uses the framework, judging by its display arguments. **/
	function appliesTo(args:Array<String>):Bool;

	/** Markup embedded in a Haxe file that contains `offset`, e.g. the string in `@:xml('...')`. **/
	function regionInHaxe(text:String, offset:Int):Null<Region>;

	/** The class that markup at `region` in a Haxe file is compiled into. **/
	function hostInHaxe(path:String, text:String, region:Region):Null<HostClass>;

	/** Whether a standalone markup file (e.g. `.xml`) is this framework's. **/
	function claimsFile(project:MarkupProject, path:String, text:String):Promise<Bool>;

	/** The class a standalone markup file is compiled into, if any. **/
	function hostOfFile(project:MarkupProject, path:String):Promise<Null<HostClass>>;

	/** Whether `name`, as written in markup, refers to `tag`. **/
	function matchesTag(tag:TagInfo, name:String):Bool;

	/** Every tag the framework knows in this project. `style` is the markup being edited, to match its naming. **/
	function tags(project:MarkupProject, style:String):Promise<Array<TagInfo>>;

	/** The attributes of a tag. **/
	function attributes(project:MarkupProject, tag:TagInfo):Promise<Array<AttributeInfo>>;

	/** How the value of `attribute` on `tag` is compiled, if it is Haxe code. `markup` is the whole markup text. **/
	function codeContext(project:MarkupProject, tag:TagInfo, attribute:String, markup:String, host:Null<HostClass>):Promise<Null<CodeContext>>;

	/** Forget what was learned from `path` (a saved or changed file). **/
	function invalidate(path:String):Void;
}

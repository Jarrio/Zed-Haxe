package bridge.lsp;

typedef EditingContext = {
	final enclosingClass:Null<String>;
	final declared:Map<String, Bool>;
}

/** What to do with private members and `_` internals in completion lists (`project.privateMembers`). **/
enum abstract PrivateMembers(String) from String to String {
	/** List them after everything else (the default). **/
	final Last = "last";

	/** Leave them out. **/
	final Hide = "hide";

	/** Keep the compiler's order. **/
	final Show = "show";
}

/**
	Ranks completion items so the members you're likely to want come first: public ones and the
	members of the class you're writing, then private members of other classes, then `_`-prefixed
	internals (HaxeUI's convention for public-but-internal) of other classes.

	Zed orders by how well an item matches what you typed and uses `sortText` for ties, so after a
	`.` with nothing typed this decides the order, and while typing it still sorts equal matches.
**/
class Ranking {
	public static inline final wanted = 0;
	public static inline final privateMember = 1;
	public static inline final internal = 2;

	/** The server prints a class field's `detail` as `public var x:T` / `private ...`, then `from class 'Name'`. **/
	static final declaredIn = ~/\n\s*from [a-z ]+ '([^']+)'/;

	/** A type declaration at the start of a line, so a doc comment saying "the class that..." doesn't count. **/
	static final classDeclaration = ~/^[ \t]*(?:(?:private|final|extern|abstract|enum)\s+)*(?:class|interface|abstract)\s+([A-Za-z_]\w*)/m;
	static final memberDeclaration = ~/\b(?:var|final|function)\s+([A-Za-z_]\w*)/g;

	/**
		Group of an LSP item from the server. `context` is the class the cursor is in and the names declared
		in the file being edited: the server doesn't always say where a field comes from, so a name declared
		in this file counts as the class's own.
	**/
	public static function ofServerItem(item:Dynamic, context:EditingContext):Int {
		final detail:String = item.detail ?? "";
		final label:String = item.label ?? "";
		final isField = StringTools.startsWith(detail, "public ") || StringTools.startsWith(detail, "private ");
		if (!isField) {
			return wanted; // locals, types, keywords...
		}
		final own = declaredIn.match(detail) ? declaredIn.matched(1) == context.enclosingClass : context.declared.exists(label);
		if (own) {
			return wanted;
		}
		if (StringTools.startsWith(label, "_")) {
			return internal;
		}
		return StringTools.startsWith(detail, "private ") ? privateMember : wanted;
	}

	/** The class at `offset` and the member names declared in `text`. **/
	public static function editingContext(text:String, offset:Int):EditingContext {
		final declared = new Map<String, Bool>();
		var rest = text;
		while (memberDeclaration.match(rest)) {
			declared.set(memberDeclaration.matched(1), true);
			rest = memberDeclaration.matchedRight();
		}
		return {enclosingClass: enclosingClass(text, offset), declared: declared};
	}

	/**
		Group of a compiler display item. After a `.` (`fieldAccess`), even the type's own private members
		are another class's internals; without one, members declared in the current class (origin `Self`) are wanted.
	**/
	public static function ofDisplayItem(item:Dynamic, fieldAccess:Bool):Int {
		if (item.kind != "ClassField") {
			return wanted;
		}
		final field:Dynamic = item.args.field;
		if (!fieldAccess && item.args.origin?.kind == 0) {
			return wanted;
		}
		if (StringTools.startsWith(field.name, "_")) {
			return internal;
		}
		return field.isPublic == false ? privateMember : wanted;
	}

	/**
		Reorders (by prefixing `sortText` with the group) or filters `items`, keeping the order within each group.
		Items without a `sortText` get one from their position, so every mode keeps the compiler's order.
	**/
	public static function apply(items:Array<Dynamic>, groups:Array<Int>, mode:PrivateMembers):Array<Dynamic> {
		for (i in 0...items.length) {
			final item = items[i];
			final original:String = item.sortText ?? StringTools.lpad(Std.string(i), "0", 6);
			item.sortText = mode == Last ? groups[i] + original : original;
		}
		return mode == Hide ? [for (i in 0...items.length) if (groups[i] == wanted) items[i]] : items;
	}

	/** Name of the class whose body contains `offset`, as far as a quick look can tell: the last one declared before it. **/
	public static function enclosingClass(text:String, offset:Int):Null<String> {
		var found:Null<String> = null;
		var rest = text.substr(0, offset);
		while (classDeclaration.match(rest)) {
			found = classDeclaration.matched(1);
			rest = classDeclaration.matchedRight();
		}
		return found;
	}
}

package bridge.lsp;

import bridge.util.HaxeTypes;

/**
	Turns the compiler's JSON display results (`haxe.display.Display`) into LSP shapes,
	for answers the bridge computes itself instead of the server.
**/
class HaxeItems {
	/**
		A completion item for a compiler display item, replacing `range` when chosen.
		Returns null for kinds that make no sense to offer, and for the bridge's own probe names.
	**/
	public static function completionItem(item:Dynamic, range:Dynamic):Null<Dynamic> {
		final args:Dynamic = item.args;
		var label:Null<String> = null;
		var kind = 6;
		var detail:Null<String> = null;
		var doc:Null<String> = null;
		switch (item.kind : String) {
			case "Local":
				label = args.name;
				kind = 6; // Variable
				detail = HaxeTypes.print(args.type);
			case "ClassField":
				label = args.field.name;
				kind = args.field.kind.kind == "FMethod" ? 2 : 10; // Method, Property
				detail = HaxeTypes.print(args.field.type);
				doc = args.field.doc;
			case "EnumField" | "EnumAbstractField":
				label = args.field.name;
				kind = 20; // EnumMember
				detail = HaxeTypes.print(args.field.type);
				doc = args.field.doc;
			case "Type":
				label = args.path.typeName;
				kind = switch (args.kind : String) {
					case "Interface": 8;
					case "Enum" | "EnumAbstract": 13;
					case "TypeAlias" | "Struct": 22;
					case _: 7; // Class
				}
				final pack:Array<String> = args.path.pack;
				detail = pack.concat([args.path.typeName]).join(".");
				doc = args.doc;
			case "Package":
				final pack:Array<String> = args.path.pack;
				label = pack[pack.length - 1];
				kind = 9; // Module
			case "Keyword" | "Literal":
				label = args.name;
				kind = item.kind == "Keyword" ? 14 : 12; // Keyword, Value
			case "TypeParameter":
				label = args.name;
				kind = 25;
			case _:
				return null;
		}
		if (label == null || StringTools.startsWith(label, "haxeZed") || label == "__this__") {
			return null;
		}
		final result:Dynamic = {
			label: label,
			kind: kind,
			textEdit: {range: range, newText: label},
			data: {haxeZed: true}
		};
		if (detail != null) {
			result.detail = detail;
		}
		if (doc != null && StringTools.trim(doc) != "") {
			result.documentation = {kind: "markdown", value: StringTools.trim(doc)};
		}
		return result;
	}

	/** LSP hover for a `display/hover` result. **/
	public static function hover(result:Dynamic):Null<Dynamic> {
		if (result == null || result.item == null) {
			return null;
		}
		final item:Dynamic = result.item;
		final name:Null<String> = switch (item.kind : String) {
			case "Local": item.args.name;
			case "ClassField" | "EnumField" | "EnumAbstractField": item.args.field.name;
			case _: null;
		}
		var value = "```haxe\n" + (name == null ? "" : '$name:') + HaxeTypes.print(item.type) + "\n```";
		final doc:Null<String> = result.documentation;
		if (doc != null && StringTools.trim(doc) != "") {
			value += "\n\n" + StringTools.trim(doc);
		}
		return {contents: {kind: "markdown", value: value}};
	}

	/** LSP signature help for a `display/signatureHelp` result. **/
	public static function signatureHelp(result:Dynamic):Null<Dynamic> {
		if (result == null || result.signatures == null) {
			return null;
		}
		final signatures:Array<Dynamic> = result.signatures;
		return {
			activeSignature: result.activeSignature ?? 0,
			activeParameter: result.activeParameter ?? 0,
			signatures: [
				for (signature in signatures) {
					final parameters = [];
					var label = "(";
					final arguments:Array<Dynamic> = signature.args ?? [];
					for (i in 0...arguments.length) {
						if (i > 0) {
							label += ", ";
						}
						final argument = arguments[i];
						final text = (argument.opt ? "?" : "") + argument.name + ":" + HaxeTypes.print(argument.t);
						parameters.push({label: [label.length, label.length + text.length]});
						label += text;
					}
					label += "):" + HaxeTypes.print(signature.ret);
					final entry:Dynamic = {label: label, parameters: parameters};
					if (signature.documentation != null) {
						entry.documentation = {kind: "markdown", value: signature.documentation};
					}
					entry;
				}
			]
		};
	}

	/** LSP locations for a `display/definition` result. **/
	public static function locations(result:Dynamic):Array<Dynamic> {
		final found:Array<Dynamic> = result ?? [];
		return [for (location in found) if (location.file != null) {uri: Rewrites.pathToUri(location.file), range: location.range}];
	}
}

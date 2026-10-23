package bridge.lsp;

import bridge.rpc.Message;

private typedef ModuleSymbol = {
	var name:String;
	var kind:Int;
	var range:{start:{line:Int, character:Int}, end:{line:Int, character:Int}};
	var ?containerName:String;
	var ?isDeprecated:Bool;
}

/**
	Workspace symbols for Haxe 5, which removed the XML `--display` mode the server still uses for them
	(vshaxe/vshaxe#693). Asks the compiler's `display/workspaceSymbols` through the server's
	`haxe/runMethod` passthrough instead. Remove once the server does this itself.
**/
class WorkspaceSymbols {
	public static function handle(bridge:Router, message:Message) {
		bridge.requestServer("haxe/runMethod", {
			method: "display/workspaceSymbols",
			params: {filter: message.params.query ?? ""}
		}).then(function(entries:Null<Array<{file:String, symbols:Array<ModuleSymbol>}>>) {
			final result = [];
			for (entry in entries ?? []) {
				final uri = Rewrites.pathToUri(entry.file);
				for (symbol in entry.symbols) {
					if (symbol.range == null) {
						continue;
					}
					final info:Dynamic = {
						name: symbol.name,
						kind: lspKind(symbol.kind),
						location: {uri: uri, range: symbol.range}
					};
					if (symbol.containerName != null) {
						info.containerName = symbol.containerName;
					}
					if (symbol.isDeprecated == true) {
						info.tags = [1];
					}
					result.push(info);
				}
			}
			bridge.replyToClient(message.id, result);
		}, function(error) {
			Log.info('display/workspaceSymbols failed: ${haxe.Json.stringify(error)}');
			bridge.replyToClient(message.id, []);
		});
	}

	/** Haxe's `ModuleSymbolKind` to LSP's `SymbolKind`, as the server maps them. **/
	static function lspKind(kind:Int):Int {
		return switch kind {
			case 1 | 5: 5; // Class, Abstract -> Class
			case 2 | 4: 11; // Interface, TypeAlias -> Interface
			case 3 | 13: 10; // Enum, EnumAbstract -> Enum
			case 6: 8; // Field
			case 7: 7; // Property
			case 8: 6; // Method
			case 9: 9; // Constructor
			case 10: 12; // Function
			case 11: 13; // Variable
			case 12: 23; // Struct
			case 14: 25; // Operator
			case 15: 22; // EnumMember
			case 16: 14; // Constant
			case 17: 2; // Module
			case _: 13;
		}
	}
}

package bridge.lsp;

import bridge.rpc.Message;

/**
	Answers Go to Type Definition and Go to Implementation through `haxe/runMethod`.

	haxe-language-server handles both itself, but when Haxe finds nothing (the type of a function,
	say) its handler fails on the `null` result and never answers. Zed asks for type definitions
	around the cursor for edit predictions, so each such request waited out Zed's two-minute timeout.
**/
class Locations {
	public static function handle(bridge:Router, documents:Documents, message:Message, haxeMethod:String) {
		final uri:String = message.params.textDocument.uri;
		final text = documents.text(uri);
		final path = Rewrites.uriToPath(uri);
		if (text == null || path == null) {
			bridge.toServer(message);
			return;
		}
		final offset = ServerCompiler.codePoints(text, Documents.offsetAt(text, message.params.position));
		bridge.requestServer("haxe/runMethod", {method: haxeMethod, params: {file: path, contents: text, offset: offset}})
			.then(result -> bridge.replyToClient(message.id, HaxeItems.locations(result)), _ -> bridge.replyToClient(message.id, []));
	}
}

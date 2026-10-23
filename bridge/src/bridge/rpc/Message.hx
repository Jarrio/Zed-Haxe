package bridge.rpc;

/**
	A JSON-RPC 2.0 message as it travels between Zed, the bridge and the language server.

	Requests have `method` and `id`, notifications have only `method`,
	responses have `id` and either `result` or `error`.
**/
typedef Message = {
	var ?jsonrpc:String;
	var ?id:Dynamic;
	var ?method:String;
	var ?params:Dynamic;
	var ?result:Dynamic;
	var ?error:ResponseError;
}

typedef ResponseError = {
	var code:Int;
	var message:String;
	var ?data:Dynamic;
}

class Messages {
	public static inline function isResponse(message:Message):Bool {
		return message.method == null && message.id != null;
	}

	public static inline function isRequest(message:Message):Bool {
		return message.method != null && message.id != null;
	}

	public static inline function isNotification(message:Message):Bool {
		return message.method != null && message.id == null;
	}
}

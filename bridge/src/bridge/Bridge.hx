package bridge;

import bridge.lsp.Rewrites;
import bridge.rpc.Connection;
import bridge.rpc.Message;
import js.Node.process;
import js.lib.Promise;
import js.node.ChildProcess;
import js.node.child_process.ChildProcess as ChildProcessObject;

/**
	Sits between Zed and haxe-language-server: every message goes through `Rewrites`,
	which forwards it unchanged unless it is one of the few the bridge handles.

	The bridge can also send its own requests to either side. Their ids start with `haxe-zed:`
	so their responses are recognised and never forwarded.
**/
class Bridge implements Router {
	static inline final idPrefix = "haxe-zed:";

	final client:Connection;
	final server:Connection;
	final serverProcess:ChildProcessObject;
	final rewrites:Rewrites;
	final waiting = new Map<String, {resolve:Dynamic->Void, reject:Dynamic->Void}>();
	var nextId = 1;

	public function new(serverPath:String) {
		// --no-deprecation hides Node's warning about the server starting Haxe through a shell.
		serverProcess = ChildProcess.spawn(process.execPath, ["--no-deprecation", serverPath], cast {stdio: ["pipe", "pipe", "inherit"]});
		serverProcess.on("error", function(error) {
			Log.info('could not start the language server ($serverPath): $error');
			process.exit(1);
		});
		serverProcess.on("exit", function(code:Null<Int>, _) {
			process.exit(code ?? 1);
		});
		process.stdin.on("end", () -> serverProcess.kill());

		client = new Connection(process.stdin, process.stdout);
		server = new Connection(serverProcess.stdout, serverProcess.stdin);
		rewrites = new Rewrites(this);

		client.onMessage = function(message) {
			Log.message("zed -> bridge", message);
			if (!settle(message)) {
				rewrites.fromClient(message);
			}
		};
		server.onMessage = function(message) {
			Log.message("server -> bridge", message);
			if (!settle(message)) {
				rewrites.fromServer(message);
			}
		};
	}

	public function toServer(message:Message) {
		Log.message("bridge -> server", message);
		server.send(message);
	}

	public function toClient(message:Message) {
		Log.message("bridge -> zed", message);
		client.send(message);
	}

	public function notifyServer(method:String, params:Dynamic) {
		toServer({method: method, params: params});
	}

	public function notifyClient(method:String, params:Dynamic) {
		toClient({method: method, params: params});
	}

	public function requestServer(method:String, params:Dynamic):Promise<Dynamic> {
		return request(toServer, method, params);
	}

	public function requestClient(method:String, params:Dynamic):Promise<Dynamic> {
		return request(toClient, method, params);
	}

	public function replyToServer(id:Dynamic, result:Dynamic) {
		toServer({id: id, result: result});
	}

	public function replyToClient(id:Dynamic, result:Dynamic) {
		toClient({id: id, result: result});
	}

	function request(send:Message->Void, method:String, params:Dynamic):Promise<Dynamic> {
		final id = idPrefix + nextId++;
		return new Promise(function(resolve, reject) {
			waiting.set(id, {resolve: resolve, reject: reject});
			send({id: id, method: method, params: params});
		});
	}

	/** Completes one of the bridge's own requests. Returns false for every other message. **/
	function settle(message:Message):Bool {
		if (!Messages.isResponse(message) || !Std.isOfType(message.id, String)) {
			return false;
		}
		final id:String = message.id;
		final pending = waiting.get(id);
		if (pending == null) {
			return StringTools.startsWith(id, idPrefix);
		}
		waiting.remove(id);
		if (message.error != null) {
			pending.reject(message.error);
		} else {
			pending.resolve(message.result);
		}
		return true;
	}
}

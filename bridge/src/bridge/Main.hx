package bridge;

import js.Node.process;

/**
	`node bridge.js --server <path to haxe-language-server's server.js> [--trace <file>]`

	Zed starts this instead of the language server; the bridge starts the server itself.
**/
class Main {
	static function main() {
		Log.install();
		final args = process.argv.slice(2);
		var serverPath:Null<String> = null;
		var i = 0;
		while (i < args.length) {
			switch args[i] {
				case "--server":
					serverPath = args[++i];
				case "--trace":
					Log.traceFile = args[++i];
				case other:
					Log.info('ignoring unknown argument $other');
			}
			i++;
		}
		if (serverPath == null) {
			Log.info("usage: bridge.js --server <server.js> [--trace <file>]");
			process.exit(2);
			return;
		}
		new Bridge(serverPath);
	}
}

package bridge.lsp;

import bridge.rpc.Message;
import haxe.Json;

/**
	What Zed is told the server can do. Zed ignores some of the server's runtime registrations, so
	those capabilities are declared up front instead; the bridge also registers file watchers and the
	features it answers itself in `.xml` layouts.
**/
class Registrations {
	/** Extra completion triggers for markup: `<` for tags, `"` for attribute values, `/` for closing tags. **/
	public static final markupTriggers = ["<", "\"", "/"];

	/** Registered by the server only once Haxe runs, which Zed ignores; declared in `initialize` instead. **/
	static final declaredUpFront = ["textDocument/typeDefinition", "textDocument/implementation"];

	final bridge:Router;
	final client:Client;
	final session:Session;
	final commands:TargetCommands;

	public function new(bridge:Router, client:Client, session:Session, commands:TargetCommands) {
		this.bridge = bridge;
		this.client = client;
		this.session = session;
		this.commands = commands;
	}

	/** Adjusts the server's answer to `initialize`. **/
	public function patchCapabilities(capabilities:Dynamic) {
		capabilities.typeDefinitionProvider = true;
		capabilities.implementationProvider = true;
		if (capabilities.completionProvider?.triggerCharacters != null) {
			addTriggers(capabilities.completionProvider.triggerCharacters);
		}
		final existing:Null<Array<String>> = capabilities.executeCommandProvider?.commands;
		capabilities.executeCommandProvider = {commands: commands.declare(existing ?? [])};
	}

	/** Passes on the server's `client/registerCapability` (`field` = `"registrations"`) or `unregisterCapability`. **/
	public function filter(message:Message, field:String) {
		final listed:Null<Array<{method:String}>> = Reflect.field(message.params, field);
		final all = listed ?? [];
		for (registration in all) {
			// Haxe completion also triggers on markup characters, for HaxeUI's @:xml.
			final options:Dynamic = (cast registration).registerOptions;
			if (registration.method == "textDocument/completion" && options?.triggerCharacters != null
				&& Json.stringify(options.documentSelector).indexOf('"haxe"') >= 0) {
				addTriggers(options.triggerCharacters);
			}
		}
		final kept = all.filter(registration -> !declaredUpFront.contains(registration.method));
		if (kept.length == 0) {
			bridge.replyToServer(message.id, null);
			return;
		}
		Reflect.setField(message.params, field, kept);
		bridge.toClient(message);
	}

	/** Lets Zed tell the server about created and deleted files, which it otherwise never does. **/
	public function registerFileWatchers() {
		if (!client.registersDynamically(["workspace", "didChangeWatchedFiles"])) {
			return;
		}
		final globs = ["**/*.hx", "**/*.hxml", "**/.haxerc", "**/module.xml"];
		for (name in session.project?.watch ?? []) {
			final glob = '**/$name';
			if (!globs.contains(glob)) {
				globs.push(glob);
			}
		}
		bridge.requestClient("client/registerCapability", {
			registrations: [
				{
					id: "haxe-zed-file-watchers",
					method: "workspace/didChangeWatchedFiles",
					registerOptions: {watchers: [for (glob in globs) {globPattern: glob}]}
				}
			]
		}).then(null, error -> Log.info('Zed refused the file watchers: ${Json.stringify(error)}'));
	}

	/**
		Asks Zed for completion, hover, go to definition and signature help in `.xml` files too, which the
		server never registers, so the bridge can answer them for UI layouts (HaxeUI). The XML language
		comes from Zed's XML extension.
	**/
	public function registerMarkupFiles() {
		if (!session.markupEnabled()) {
			return;
		}
		final selector = [{language: "xml"}];
		final wanted:Array<{method:String, capability:String, options:Dynamic}> = [
			{
				method: "textDocument/completion",
				capability: "completion",
				options: {documentSelector: selector, triggerCharacters: ["<", " ", "\"", "/", ".", "("], resolveProvider: true}
			},
			{method: "textDocument/hover", capability: "hover", options: {documentSelector: selector}},
			{method: "textDocument/definition", capability: "definition", options: {documentSelector: selector}},
			{method: "textDocument/signatureHelp", capability: "signatureHelp", options: {documentSelector: selector, triggerCharacters: ["(", ","]}}
		];
		final registrations = [
			for (entry in wanted)
				if (client.registersDynamically(["textDocument", entry.capability]))
					{id: 'haxe-zed-markup-${entry.capability}', method: entry.method, registerOptions: entry.options}
		];
		if (registrations.length > 0) {
			bridge.requestClient("client/registerCapability", {registrations: registrations})
				.then(null, error -> Log.info('Zed refused markup registrations: ${Json.stringify(error)}'));
		}
	}

	static function addTriggers(triggers:Array<String>) {
		for (trigger in markupTriggers) {
			if (!triggers.contains(trigger)) {
				triggers.push(trigger);
			}
		}
	}
}

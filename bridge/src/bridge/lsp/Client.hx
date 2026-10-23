package bridge.lsp;

enum abstract MessageType(Int) to Int {
	final Error = 1;
	final Warning = 2;
	final Info = 3;
}

/**
	Zed, as the bridge's own code sees it: what it supports, whether it is ready yet, and the
	progress and messages the bridge shows there.
**/
class Client {
	/** The `capabilities` from Zed's `initialize`. **/
	public var capabilities:Dynamic = {};

	/** Zed sent `initialized`; until then it can't take requests or show anything. **/
	public var initialized(default, null) = false;

	final bridge:Router;

	/** Warnings collected before Zed could show them, or during a project update. **/
	var warnings:Array<String> = [];

	public function new(bridge:Router) {
		this.bridge = bridge;
	}

	public function markInitialized() {
		initialized = true;
	}

	/** Zed registers this capability at runtime (`dynamicRegistration`), e.g. `["workspace", "didChangeWatchedFiles"]`. **/
	public function registersDynamically(path:Array<String>):Bool {
		var node:Dynamic = capabilities;
		for (key in path) {
			node = node == null ? null : Reflect.field(node, key);
		}
		return node?.dynamicRegistration == true;
	}

	/** Shows `title` in Zed's status bar until the returned function is called. **/
	public function startProgress(title:String):() -> Void {
		if (!initialized || capabilities.window?.workDoneProgress != true) {
			return function() {};
		}
		final token = 'haxe-zed-progress-${Date.now().getTime()}';
		bridge.requestClient("window/workDoneProgress/create", {token: token}).then(null, _ -> null);
		bridge.notifyClient("$/progress", {token: token, value: {kind: "begin", title: title}});
		return () -> bridge.notifyClient("$/progress", {token: token, value: {kind: "end"}});
	}

	/**
		Zed hides a plain `window/showMessage` after five seconds (`global_lsp_settings.notifications.dismiss_timeout_ms`),
		too short for a warning that asks you to do something. One with a button stays until it is clicked.
	**/
	public function showMessage(type:MessageType, message:String) {
		bridge.requestClient("window/showMessageRequest", {type: type, message: message, actions: [{title: "OK"}]}).then(null, _ -> null);
	}

	/** Keeps `warning` for the next `flushWarnings`. **/
	public function warn(warning:String) {
		warnings.push(warning);
	}

	/** Shows the collected warnings, all at once, once Zed is ready. **/
	public function flushWarnings() {
		if (!initialized || warnings.length == 0) {
			return;
		}
		for (warning in warnings) {
			Log.info('warning: $warning');
		}
		showMessage(Warning, warnings.join("\n\n"));
		warnings = [];
	}
}

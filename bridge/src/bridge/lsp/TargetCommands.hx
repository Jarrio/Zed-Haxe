package bridge.lsp;

import bridge.lsp.Client.MessageType;
import haxe.Json;

/**
	The `Haxe: target …` and `Haxe: build type …` commands. Zed lists them in `lsp command selector: toggle`,
	the closest it has to a target switcher, since extensions can't add status bar items. Also the
	once-per-project prompt that offers the targets as buttons.
**/
class TargetCommands {
	/** Opens the target buttons. `haxe.selectTarget` is the older name, still accepted. **/
	static inline final chooseTarget = "Haxe: choose target";

	static final target = ~/^Haxe: target (.+?)( \(current\))?$/;
	static final buildType = ~/^Haxe: build type (.+?)( \(current\))?$/;

	final bridge:Router;
	final client:Client;
	final session:Session;

	/** The command list last given to Zed, to only re-register it when it changes. **/
	var registered:Null<String>;

	public function new(bridge:Router, client:Client, session:Session) {
		this.bridge = bridge;
		this.client = client;
		this.session = session;
	}

	/** The commands for the current project, with `(current)` after the target and build type in use. **/
	public function list():Array<String> {
		final commands = [chooseTarget];
		final current = session.project;
		if (current == null) {
			return commands;
		}
		for (name in current.targets) {
			commands.push('Haxe: target $name' + (name == current.target ? " (current)" : ""));
		}
		final chosen = session.currentBuildType();
		for (type in current.buildTypes) {
			commands.push('Haxe: build type $type' + (type == chosen ? " (current)" : ""));
		}
		return commands;
	}

	/** The command list for the answer to `initialize`: the server's own commands, then these. **/
	public function declare(serverCommands:Array<String>):Array<String> {
		final commands = serverCommands.concat(list());
		registered = Json.stringify(commands);
		return commands;
	}

	/** Zed replaces the startup command list with the latest registration, so the whole list is sent each time. **/
	public function update() {
		final commands = list();
		final json = Json.stringify(commands);
		if (json == registered || !client.registersDynamically(["workspace", "executeCommand"])) {
			return;
		}
		registered = json;
		bridge.requestClient("client/registerCapability", {
			registrations: [
				{
					id: "haxe-zed-commands",
					method: "workspace/executeCommand",
					registerOptions: {commands: commands}
				}
			]
		}).then(null, error -> Log.info('Zed refused the command list: ${Json.stringify(error)}'));
	}

	public function handles(command:String):Bool {
		return command == chooseTarget || command == "haxe.selectTarget" || target.match(command) || buildType.match(command);
	}

	public function run(command:String) {
		if (target.match(command)) {
			session.pickTarget(target.matched(1));
		} else if (buildType.match(command)) {
			session.pickBuildType(buildType.matched(1));
		} else {
			prompt();
		}
	}

	/** The first time a framework project is opened, offers its targets. **/
	public function promptOnce() {
		// Plain hxml projects usually have one obvious build file, so only ask for framework targets.
		if (session.project?.provider != "hxml" && !session.state.wasPrompted(session.projectRoot()) && session.settings.target == null) {
			prompt();
		}
	}

	/** Offers the detected targets as buttons. **/
	function prompt() {
		final current = session.project;
		if (current == null || current.targets.length < 2) {
			return;
		}
		session.state.setPrompted(session.projectRoot());
		final targets = current.targets.slice(0, 12);
		bridge.requestClient("window/showMessageRequest", {
			type: Info,
			message: 'Haxe: using the ${current.provider} target "${current.target}". Pick another target, or set `project.target` in your settings.',
			actions: [for (name in targets) {title: name}]
		}).then(function(choice:Null<{title:String}>) {
			if (choice == null) {
				return;
			}
			if (choice.title == current.target) {
				session.state.setTarget(session.projectRoot(), choice.title);
			} else {
				session.pickTarget(choice.title);
			}
		}, error -> Log.info('target prompt failed: ${Json.stringify(error)}'));
	}
}

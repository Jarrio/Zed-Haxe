package bridge.project;

import bridge.project.ProjectProvider;
import bridge.util.Exec;
import bridge.util.Files;
import haxe.Json;
import haxe.io.Path;
import js.lib.Promise;

private typedef IdeInfo = {
	var ide:{
		var targets:Array<{
			var name:String;
			var ?select:{command:String, args:Array<String>};
		}>;
	};
}

/**
	Ceramic projects (`ceramic.yml`), following what the vscode-ceramic extension does:
	`ceramic ide info` lists the targets, and each target's "select" command
	(e.g. `ceramic clay hxml web --setup`) prints the hxml.

	Ceramic ships its own Haxe and haxelib repository, so `ceramic haxe` is returned as `haxePath`.
	Users can still override it with `project.haxePath` or by removing `"provider"` from `project.haxeResolvers`.
**/
class CeramicProvider implements ProjectProvider {
	public var name(default, null):String = "ceramic";
	public var priority(default, null):Int = 100;

	/** Select commands per project file, keyed by target name. **/
	final selectCommands = new Map<String, Map<String, Array<String>>>();

	public function new() {}

	public function detect(ctx:ProjectContext):Array<String> {
		return Files.findByName(ctx.projectRoot, ["ceramic.yml"], 2);
	}

	public function targets(ctx:ProjectContext, file:String):Promise<Array<String>> {
		return ceramic(ctx, file, ["ide", "info", "--print-split-lines"]).then(function(stdout) {
			final info:IdeInfo = Json.parse(stdout);
			final commands = new Map<String, Array<String>>();
			final names = [];
			for (target in info.ide.targets) {
				final select = target.select;
				// e.g. ["clay", "hxml", "web", "--setup"]
				if (select == null || select.args.length < 3 || select.args[1] != "hxml") {
					continue;
				}
				final targetName = select.args[2];
				if (!commands.exists(targetName)) {
					commands.set(targetName, select.args);
					names.push(targetName);
				}
			}
			selectCommands.set(file, commands);
			return names;
		});
	}

	public function resolve(ctx:ProjectContext, file:String, target:Null<String>):Promise<ProviderResult> {
		final known = selectCommands.get(file);
		final targetName = target ?? "web";
		var args = known != null && known.exists(targetName) ? known.get(targetName).copy() : ["clay", "hxml", targetName, "--setup"];
		if (ctx.settings.buildType == "debug") {
			args.push("--debug");
		}
		return ceramic(ctx, file, args).then(function(hxml) {
			return ceramic(ctx, file, ["haxe"]).then(function(haxePath):ProviderResult {
				return {
					args: Hxml.parse(hxml),
					haxePath: StringTools.trim(haxePath),
					watch: ["ceramic.yml"]
				};
			});
		});
	}

	public function watch():Array<String> {
		return ["ceramic.yml"];
	}

	/** `ceramic <backend> run|build <target>`, with the backend each target's select command names. **/
	public function tasks(ctx:ProjectContext, file:String, targets:Array<String>):Array<TaskSpec> {
		final known = selectCommands.get(file);
		final debug = ctx.settings.buildType == "debug" ? ["--debug"] : [];
		final result = [];
		for (target in targets) {
			final backend = known != null && known.exists(target) ? known.get(target)[0] : "clay";
			for (action in ["run", "build"]) {
				result.push({
					label: 'ceramic: $action $target',
					command: ["ceramic", backend, action, target, "--setup", "--assets"].concat(debug),
					cwd: Path.directory(file),
					target: target
				});
			}
		}
		return result;
	}

	public function buildTypes():Array<String> {
		return ["debug", "release"];
	}

	function ceramic(ctx:ProjectContext, file:String, args:Array<String>):Promise<String> {
		final options:ExecOptions = {cwd: Path.directory(file), env: ctx.env, aliases: ctx.settings.commands};
		return Exec.run(["ceramic"].concat(args), options).then(function(result) {
			if (result.code != 0) {
				throw 'ceramic: `ceramic ${args.join(" ")}` failed with exit code ${result.code}\n${result.stderr}${result.stdout}';
			}
			return result.stdout;
		});
	}
}

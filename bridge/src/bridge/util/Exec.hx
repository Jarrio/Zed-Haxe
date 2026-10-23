package bridge.util;

import haxe.DynamicAccess;
import js.Node.process;
import js.lib.Error;
import js.lib.Promise;
import js.node.Buffer;
import js.node.ChildProcess;

typedef ExecOptions = {
	/** Working directory of the command. **/
	var cwd:String;

	/** Full environment of the command. **/
	var env:DynamicAccess<String>;

	/** Replacements for the executable, keyed by its name (see `ProjectSettings.commands`). **/
	var ?aliases:DynamicAccess<String>;

	/** Milliseconds before the command is killed. Default two minutes. **/
	var ?timeout:Int;
}

typedef ExecResult = {
	var code:Int;
	var stdout:String;
	var stderr:String;
}

/**
	Runs external commands (`lime`, `ceramic`, `haxelib`, ...) without a shell.
**/
class Exec {
	static final isWindows = process.platform == "win32";

	/**
		Runs `command` (executable first, then arguments).
		Rejects with `NotFound` when the executable doesn't exist, otherwise resolves with the exit code and output.
	**/
	public static function run(command:Array<String>, options:ExecOptions):Promise<ExecResult> {
		final executable = alias(command[0], options.aliases);
		return new Promise(function(resolve, reject) {
			final child = ChildProcess.spawn(executable, command.slice(1), cast {
				cwd: options.cwd,
				env: options.env,
				// Windows needs a shell to run .cmd/.bat launchers such as haxelib.cmd.
				shell: isWindows,
				windowsHide: true
			});
			final stdout = [];
			final stderr = [];
			final timer = haxe.Timer.delay(function() {
				child.kill();
				reject('`${command.join(" ")}` did not finish within ${Std.int((options.timeout ?? 120000) / 1000)} seconds');
			}, options.timeout ?? 120000);
			child.stdout.on("data", (chunk:Buffer) -> stdout.push(chunk));
			child.stderr.on("data", (chunk:Buffer) -> stderr.push(chunk));
			child.on("error", function(error:Error) {
				timer.stop();
				if ((cast error).code == "ENOENT") {
					reject(new NotFound(executable));
				} else {
					reject(error);
				}
			});
			child.on("close", function(code:Null<Int>, _) {
				timer.stop();
				resolve({
					code: code == null ? -1 : code,
					stdout: Buffer.concat(stdout).toString("utf8"),
					stderr: Buffer.concat(stderr).toString("utf8")
				});
			});
		});
	}

	/**
		Tries each command in turn, moving on only when the executable isn't found.
		Useful for `lime ...` with `haxelib run lime ...` as a fallback.
	**/
	public static function runFirst(alternatives:Array<Array<String>>, options:ExecOptions):Promise<ExecResult> {
		if (alternatives.length == 0) {
			return Promise.reject(new NotFound("(no command)"));
		}
		return run(alternatives[0], options).then(null, function(error:Dynamic) {
			if (Std.isOfType(error, NotFound) && alternatives.length > 1) {
				return runFirst(alternatives.slice(1), options);
			}
			return Promise.reject(error);
		});
	}

	/** Synchronous variant for quick queries such as `haxe --version`. Returns null when the executable doesn't exist. **/
	public static function runSync(command:Array<String>, options:ExecOptions):Null<ExecResult> {
		final result = ChildProcess.spawnSync(alias(command[0], options.aliases), command.slice(1), cast {
			cwd: options.cwd,
			env: options.env,
			shell: isWindows,
			windowsHide: true,
			encoding: "utf8",
			timeout: 15000
		});
		if (result.error != null) {
			return null;
		}
		return {
			code: result.status == null ? -1 : result.status,
			stdout: Std.string(result.stdout),
			stderr: Std.string(result.stderr)
		};
	}

	static function alias(executable:String, aliases:Null<DynamicAccess<String>>):String {
		if (aliases != null && aliases.exists(executable)) {
			return aliases.get(executable);
		}
		return executable;
	}
}

class NotFound {
	public final executable:String;

	public function new(executable:String) {
		this.executable = executable;
	}

	public function toString() {
		return '`$executable` was not found on PATH';
	}
}

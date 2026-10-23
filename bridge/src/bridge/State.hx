package bridge;

import haxe.DynamicAccess;
import haxe.Json;
import haxe.io.Path;
import js.Node.process;
import sys.FileSystem;
import sys.io.File;

private typedef ProjectState = {
	/** Target the user picked from the prompt. **/
	var ?target:String;

	/** Whether the target prompt was already shown for this project. **/
	var ?prompted:Bool;

	/** Build type picked with the `Haxe: build type ...` commands. **/
	var ?buildType:String;
}

/**
	Small per-project memory kept outside the project, e.g. in `~/.local/state/haxe-zed/state.json`.
**/
class State {
	public final dir:String;

	final file:String;
	var projects:DynamicAccess<ProjectState>;

	/** @param dir where to keep the file; defaults to the platform's state folder **/
	public function new(?dir:String) {
		this.dir = dir ?? stateDir();
		file = Path.join([this.dir, "state.json"]);
		projects = try Json.parse(File.getContent(file)) catch (_) {};
	}

	public function target(projectRoot:String):Null<String> {
		return projects.get(projectRoot)?.target;
	}

	public function setTarget(projectRoot:String, target:String) {
		entry(projectRoot).target = target;
		save();
	}

	public function buildType(projectRoot:String):Null<String> {
		return projects.get(projectRoot)?.buildType;
	}

	public function setBuildType(projectRoot:String, buildType:String) {
		entry(projectRoot).buildType = buildType;
		save();
	}

	public function wasPrompted(projectRoot:String):Bool {
		return projects.get(projectRoot)?.prompted == true;
	}

	public function setPrompted(projectRoot:String) {
		entry(projectRoot).prompted = true;
		save();
	}

	function entry(projectRoot:String):ProjectState {
		if (!projects.exists(projectRoot)) {
			projects.set(projectRoot, {});
		}
		return projects.get(projectRoot);
	}

	function save() {
		try {
			FileSystem.createDirectory(dir);
			File.saveContent(file, Json.stringify(projects, "  "));
		} catch (e) {
			Log.info('could not save $file: $e');
		}
	}

	static function stateDir():String {
		final env = process.env;
		// Tests point this at a folder of their own.
		final explicit = env.get("HAXE_ZED_STATE_DIR");
		if (explicit != null && explicit != "") {
			return explicit;
		}
		final home = env.get("HOME") ?? env.get("USERPROFILE") ?? ".";
		return switch process.platform {
			case "win32": Path.join([env.get("LOCALAPPDATA") ?? home, "haxe-zed"]);
			case "darwin": Path.join([home, "Library", "Application Support", "haxe-zed"]);
			case _: Path.join([env.get("XDG_STATE_HOME") ?? Path.join([home, ".local", "state"]), "haxe-zed"]);
		}
	}
}

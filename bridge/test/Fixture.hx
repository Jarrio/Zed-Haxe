import bridge.Settings.ProjectSettings;
import bridge.project.ProjectProvider.ProjectContext;
import haxe.DynamicAccess;
import haxe.io.Path;
import js.Node.process;
import js.node.Fs;
import js.node.Os;
import sys.FileSystem;

/** Temporary project folders for tests. **/
class Fixture {
	static final created:Array<String> = [];

	/** Creates a temporary folder containing `files` (relative path => content). **/
	public static function create(files:DynamicAccess<String>):String {
		final dir = Fs.realpathSync(Fs.mkdtempSync(Path.join([Os.tmpdir(), "haxe-zed-test-"])));
		created.push(dir);
		for (name => content in files) {
			final path = Path.join([dir, name]);
			FileSystem.createDirectory(Path.directory(path));
			sys.io.File.saveContent(path, content);
		}
		return dir;
	}

	/** Makes `dir/name` an executable shell script. **/
	public static function script(dir:String, name:String, body:String):String {
		final path = Path.join([dir, name]);
		FileSystem.createDirectory(Path.directory(path));
		sys.io.File.saveContent(path, '#!/bin/sh\n$body\n');
		Fs.chmodSync(path, "755");
		return path;
	}

	public static function context(dir:String, ?settings:ProjectSettings):ProjectContext {
		final settings:ProjectSettings = settings ?? {};
		return {
			workspaceRoot: dir,
			projectRoot: settings.root == null ? dir : Path.join([dir, settings.root]),
			settings: settings,
			env: process.env
		};
	}

	/** Deletes every folder made by `create`. **/
	public static function removeAll() {
		for (dir in created) {
			js.Syntax.code("require('fs').rmSync({0}, {recursive: true, force: true})", dir);
		}
		created.resize(0);
	}

	/** A `node -e <script>` command, for definitions that need a real executable. **/
	public static function node(script:String, ?args:Array<String>):Array<String> {
		return [process.execPath, "-e", script].concat(args ?? []);
	}
}

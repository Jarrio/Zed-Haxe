package bridge;

#if macro
import haxe.io.Path;
import haxe.macro.Context;
import sys.FileSystem;
import sys.io.File;

/**
	Build macro that embeds every file of a folder as a resource, so dropping a JSON file into
	`providers/` or `docs/` is enough to ship it. Used from build.hxml:
	`--macro bridge.Embed.folder("providers")`.
**/
class Embed {
	public static function folder(dir:String) {
		if (!FileSystem.exists(dir)) {
			return;
		}
		for (file in FileSystem.readDirectory(dir)) {
			final path = Path.join([dir, file]);
			if (!FileSystem.isDirectory(path)) {
				Context.addResource('$dir/$file', File.getBytes(path));
			}
		}
	}
}
#end

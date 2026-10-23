package bridge.project;

import bridge.project.ProviderDefinition.DocPack;
import haxe.Resource;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
	Turns documentation packs into `--macro` arguments that register them with the compiler
	(Haxe 4.3+), so library metadata and defines show up in completion and hover.
**/
class DocPacks {
	/**
		@param builtInDir folder where packs shipped inside the bridge (`builtin:<name>`) are written out
	**/
	public static function macros(packs:Array<DocPack>, args:Array<String>, projectRoot:String, builtInDir:String):Array<String> {
		final result = [];
		for (pack in packs) {
			if (pack.lib != null && !mentions(args, pack.lib)) {
				continue;
			}
			final source = pack.lib ?? "project";
			final metadata = pack.metadata == null ? null : file(pack.metadata, projectRoot, builtInDir);
			if (metadata != null) {
				result.push("--macro");
				result.push('haxe.macro.Compiler.registerMetadataDescriptionFile(\'$metadata\', \'$source\')');
			}
			final defines = pack.defines == null ? null : file(pack.defines, projectRoot, builtInDir);
			if (defines != null) {
				result.push("--macro");
				result.push('haxe.macro.Compiler.registerDefinesDescriptionFile(\'$defines\', \'$source\')');
			}
		}
		return result;
	}

	/** Whether the arguments use `lib`, as `-lib lib[:version]` or `-D lib[=version]`. **/
	public static function mentions(args:Array<String>, lib:String):Bool {
		for (i in 0...args.length - 1) {
			final flag = args[i];
			final value = args[i + 1];
			final isLib = flag == "-lib" || flag == "-L" || flag == "--library";
			final isDefine = flag == "-D" || flag == "--define";
			if ((isLib && (value == lib || StringTools.startsWith(value, '$lib:')))
				|| (isDefine && (value == lib || StringTools.startsWith(value, '$lib=')))) {
				return true;
			}
		}
		return false;
	}

	/** Absolute path of a pack file with forward slashes, or null if it doesn't exist. **/
	static function file(reference:String, projectRoot:String, builtInDir:String):Null<String> {
		var path = reference;
		if (StringTools.startsWith(reference, "builtin:")) {
			final name = reference.substr("builtin:".length);
			final content = Resource.getString('docs/$name');
			if (content == null) {
				return null;
			}
			FileSystem.createDirectory(builtInDir);
			path = Path.join([builtInDir, name]);
			File.saveContent(path, content);
		} else if (!Path.isAbsolute(reference)) {
			path = Path.join([projectRoot, reference]);
		}
		if (!FileSystem.exists(path)) {
			return null;
		}
		return path.split("\\").join("/");
	}
}

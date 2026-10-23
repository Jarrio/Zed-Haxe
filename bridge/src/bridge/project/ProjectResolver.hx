package bridge.project;

import bridge.project.ProjectProvider;
import bridge.project.ProviderDefinition.DocPack;
import js.lib.Promise;
import sys.FileSystem;
import haxe.io.Path;

typedef ResolvedProject = {
	/** Name of the provider that produced the arguments (`"settings"` and `"default"` are special). **/
	final provider:String;

	/** Project file the provider detected, if any. **/
	final ?file:String;

	final targets:Array<String>;
	final ?target:String;
	final args:Array<String>;
	final ?haxePath:String;

	/** File names whose change should trigger re-resolution. **/
	final watch:Array<String>;

	final docs:Array<DocPack>;

	/** Build and run commands for the editor's task list. **/
	final tasks:Array<TaskSpec>;

	/** Build types the provider supports, for switching. **/
	final buildTypes:Array<String>;

	/** Problems worth showing to the user, e.g. a provider command that failed. **/
	final warnings:Array<String>;
}

/**
	Picks a provider and target for a folder and computes the display arguments.
**/
class ProjectResolver {
	/**
		@param remembered the target the user picked last time for this project, if any
	**/
	public static function resolve(ctx:ProjectContext, remembered:Null<String>):Promise<ResolvedProject> {
		final settings = ctx.settings;
		if (settings.args != null) {
			return Promise.resolve(({
				provider: "settings",
				targets: [],
				args: settings.args,
				watch: [],
				docs: [],
				tasks: [],
				buildTypes: [],
				warnings: []
			} : ResolvedProject));
		}

		var providers = Registry.providers(settings);
		final warnings = [];
		if (settings.provider != null) {
			final forced = providers.filter(p -> p.name == settings.provider);
			if (forced.length == 0) {
				warnings.push('No project provider is called "${settings.provider}"; detecting automatically.');
			} else {
				providers = forced;
			}
		}
		final allWatched = [];
		for (provider in providers) {
			for (name in provider.watch()) {
				if (!allWatched.contains(name)) {
					allWatched.push(name);
				}
			}
		}
		return tryProviders(ctx, providers, remembered, warnings, allWatched);
	}

	static function tryProviders(ctx:ProjectContext, providers:Array<ProjectProvider>, remembered:Null<String>, warnings:Array<String>,
			allWatched:Array<String>):Promise<ResolvedProject> {
		if (providers.length == 0) {
			return Promise.resolve(fallback(ctx, warnings, allWatched));
		}
		final provider = providers[0];
		final rest = providers.slice(1);
		final files = try provider.detect(ctx) catch (e) {
			warnings.push('${provider.name}: detection failed: $e');
			[];
		}
		if (files.length == 0) {
			return tryProviders(ctx, rest, remembered, warnings, allWatched);
		}
		final file = files[0];
		return provider.targets(ctx, file).then(function(targets) {
			final target = chooseTarget(ctx.settings.target, remembered, targets);
			return provider.resolve(ctx, file, target).then(function(result):ResolvedProject {
				final watch = allWatched.concat(result.watch ?? []);
				return {
					provider: provider.name,
					file: file,
					targets: targets,
					target: target,
					args: result.args,
					haxePath: result.haxePath,
					watch: watch,
					docs: result.docs ?? [],
					tasks: try provider.tasks(ctx, file, targets) catch (_) [],
					buildTypes: provider.buildTypes(),
					warnings: warnings
				};
			});
		}).then(null, function(error:Dynamic) {
			warnings.push(Std.string(error));
			return tryProviders(ctx, rest, remembered, warnings, allWatched);
		});
	}

	public static function chooseTarget(configured:Null<String>, remembered:Null<String>, targets:Array<String>):Null<String> {
		if (configured != null) {
			return configured;
		}
		if (remembered != null && targets.contains(remembered)) {
			return remembered;
		}
		return targets.length > 0 ? targets[0] : null;
	}

	/** Used when no provider recognises the folder: treat `src/` (or the root) as a class path. **/
	static function fallback(ctx:ProjectContext, warnings:Array<String>, allWatched:Array<String>):ResolvedProject {
		final src = Path.join([ctx.projectRoot, "src"]);
		final classPath = FileSystem.exists(src) && FileSystem.isDirectory(src) ? src : ctx.projectRoot;
		return {
			provider: "default",
			targets: [],
			args: ["--class-path", classPath],
			watch: allWatched,
			docs: [],
			tasks: [],
			buildTypes: [],
			warnings: warnings
		};
	}
}

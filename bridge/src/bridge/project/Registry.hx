package bridge.project;

import bridge.Settings.ProjectSettings;
import haxe.Json;
import haxe.Resource;

/**
	Collects the available project providers from three places:
	1. JSON definitions shipped in `bridge/providers/`
	2. JSON definitions from `project.providers` in the user's settings (same name replaces a built-in)
	3. providers written in Haxe, listed in `codeProviders`
**/
class Registry {
	/** Providers written in Haxe. A JSON definition with the same name replaces one of these too. **/
	static function codeProviders():Array<ProjectProvider> {
		return [new CeramicProvider(), new HxmlProvider()];
	}

	public static function providers(settings:ProjectSettings):Array<ProjectProvider> {
		final definitions = new Map<String, ProviderDefinition>();
		final order = [];
		function add(definition:ProviderDefinition) {
			if (!definitions.exists(definition.name)) {
				order.push(definition.name);
			}
			definitions.set(definition.name, definition);
		}
		for (definition in builtInDefinitions()) {
			add(definition);
		}
		for (definition in settings.providers ?? []) {
			add(definition);
		}

		final result:Array<ProjectProvider> = [for (name in order) new CommandProvider(definitions.get(name))];
		for (provider in codeProviders()) {
			if (!definitions.exists(provider.name)) {
				result.push(provider);
			}
		}
		result.sort(function(a, b) {
			if (a.priority != b.priority) {
				return b.priority - a.priority;
			}
			return Reflect.compare(a.name, b.name);
		});
		return result;
	}

	public static function builtInDefinitions():Array<ProviderDefinition> {
		final names = Resource.listNames().filter(name -> StringTools.startsWith(name, "providers/") && StringTools.endsWith(name, ".json"));
		names.sort(Reflect.compare);
		return [for (name in names) Json.parse(Resource.getString(name))];
	}
}

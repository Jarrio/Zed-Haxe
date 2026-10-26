import bridge.project.CommandProvider;
import bridge.project.HxmlProvider;
import bridge.project.ProjectResolver;
import bridge.project.Registry;
import haxe.io.Path;
import utest.Assert;
import utest.Async;

/** Project providers: JSON definitions, the hxml provider, the registry and the resolver. **/
class ProvidersTest extends utest.Test {
	@:timeout(10000)
	function testCommandWithHxmlOutput(async:Async) {
		final dir = Fixture.create({"game.json": ""});
		final provider = new CommandProvider({
			name: "fake",
			detect: ["game.json"],
			args: {command: Fixture.node("console.log('-cp src\\n-D ' + process.argv[1])", ["${target}"])}
		});
		final file = provider.detect(Fixture.context(dir))[0];
		Assert.equals(Path.join([dir, "game.json"]), file);
		provider.resolve(Fixture.context(dir), file, "html5").then(function(result) {
			Assert.same(["-cp", "src", "-D", "html5"], result.args);
			async.done();
		}, error -> fail(async, error));
	}

	@:timeout(10000)
	function testCommandWithJsonOutput(async:Async) {
		final dir = Fixture.create({"game.json": ""});
		final provider = new CommandProvider({
			name: "fake",
			detect: ["game.json"],
			args: {command: Fixture.node("console.log(JSON.stringify({args: ['-cp', 'gen'], haxePath: '/opt/haxe/haxe'}))"), output: "json"}
		});
		provider.resolve(Fixture.context(dir), Path.join([dir, "game.json"]), null).then(function(result) {
			Assert.same(["-cp", "gen"], result.args);
			Assert.equals("/opt/haxe/haxe", result.haxePath);
			async.done();
		}, error -> fail(async, error));
	}

	@:timeout(10000)
	function testCommandWritingAnHxmlFile(async:Async) {
		final dir = Fixture.create({"game.json": "", "build/.keep": ""});
		final provider = new CommandProvider({
			name: "fake",
			detect: ["game.json"],
			args: {
				command: Fixture.node("require('fs').writeFileSync('build/project-' + process.argv[1] + '.hxml', '-cp gen')", ["${target}"]),
				output: {file: "build/project-${target}.hxml"}
			}
		});
		provider.resolve(Fixture.context(dir), Path.join([dir, "game.json"]), "web").then(function(result) {
			Assert.same(["-cp", "gen"], result.args);
			async.done();
		}, error -> fail(async, error));
	}

	@:timeout(10000)
	function testProjectInSubfolderGetsCwd(async:Async) {
		final dir = Fixture.create({"game/game.json": ""});
		final provider = new CommandProvider({name: "fake", detect: ["game.json"], args: {command: Fixture.node("console.log('-cp src')")}});
		final file = provider.detect(Fixture.context(dir))[0];
		provider.resolve(Fixture.context(dir), file, null).then(function(result) {
			Assert.same(["--cwd", Path.join([dir, "game"]), "-cp", "src"], result.args);
			async.done();
		}, error -> fail(async, error));
	}

	@:timeout(10000)
	function testFallsBackToNextCommand(async:Async) {
		final dir = Fixture.create({"game.json": ""});
		final provider = new CommandProvider({
			name: "fake",
			detect: ["game.json"],
			args: {command: [["haxe-zed-test-missing-tool"], Fixture.node("console.log('-cp ok')")]}
		});
		provider.resolve(Fixture.context(dir), Path.join([dir, "game.json"]), null).then(function(result) {
			Assert.same(["-cp", "ok"], result.args);
			async.done();
		}, error -> fail(async, error));
	}

	@:timeout(10000)
	function testFailingCommandRejects(async:Async) {
		final dir = Fixture.create({"game.json": ""});
		final provider = new CommandProvider({name: "fake", detect: ["game.json"], args: {command: Fixture.node("process.exit(3)")}});
		provider.resolve(Fixture.context(dir), Path.join([dir, "game.json"]), null).then(function(_) {
			Assert.fail("expected a rejection");
			async.done();
		}, function(error) {
			Assert.stringContains("exit code 3", Std.string(error));
			async.done();
		});
	}

	function testHxmlProviderPrefersBuildFiles() {
		final dir = Fixture.create({
			"test.hxml": "",
			"common.hxml": "",
			"build.hxml": "",
			"extraParams.hxml": "",
			"sub/compile.hxml": "",
			"node_modules/lib/build.hxml": "",
			"haxe_modules/mysql/tests/test-hl.hxml": "",
			"vendor/somelib/haxelib.json": "{}",
			"vendor/somelib/build.hxml": ""
		});
		final provider = new HxmlProvider();
		final found = provider.detect(Fixture.context(dir)).map(Path.withoutDirectory);
		Assert.equals("build.hxml", found[0]);
		Assert.isFalse(found.contains("extraParams.hxml"));
		Assert.equals(4, found.length); // node_modules, haxe_modules and libraries kept in the project are skipped
	}

	function testHxmlProviderPrefersFilesThatBuildSomething() {
		// Like the SkiaHaxeuiTemplate: android.hxml only adds defines to common.hxml, its output comes from another tool.
		final dir = Fixture.create({
			"common.hxml": "-cp src\n-main Main",
			"android.hxml": "common.hxml\n-D android",
			"hxcpp.hxml": "common.hxml\n--cpp bin/cpp"
		});
		final found = new HxmlProvider().detect(Fixture.context(dir)).map(Path.withoutDirectory);
		Assert.equals("hxcpp.hxml", found[0]);
		Assert.equals("common.hxml", found[found.length - 1]);
	}

	function testHxmlProviderPrefersFilesSeeingMoreClassPaths() {
		// Like the SkiaHaxeuiTemplate: the cppia host only has main/, the desktop build has main/ and src/.
		final dir = Fixture.create({
			"common.hxml": "--library haxeui-core",
			"cppia.hxml": "common.hxml\n-cp main\n--cpp bin/cppia",
			"hxcpp.hxml": "common.hxml\n-cp main\n-cp src\n--cpp bin/cpp"
		});
		Assert.equals("hxcpp.hxml", Path.withoutDirectory(new HxmlProvider().detect(Fixture.context(dir))[0]));
	}

	@:timeout(5000)
	function testHxmlInSubfolderRunsFromThere(async:Async) {
		final dir = Fixture.create({"sub/compile.hxml": ""});
		final provider = new HxmlProvider();
		provider.resolve(Fixture.context(dir), Path.join([dir, "sub/compile.hxml"]), "sub/compile.hxml").then(function(result) {
			Assert.same(["--cwd", Path.join([dir, "sub"]), "compile.hxml"], result.args);
			async.done();
		}, error -> fail(async, error));
	}

	function testSettingsReplaceBuiltInsByName() {
		final providers = Registry.providers({
			providers: [{name: "lime", priority: 7, detect: ["custom.xml"], args: {command: ["true"]}}]
		});
		final limes = providers.filter(p -> p.name == "lime");
		Assert.equals(1, limes.length);
		Assert.equals(7, limes[0].priority);
		Assert.equals("hxml", providers[providers.length - 1].name); // lowest priority
	}

	@:timeout(10000)
	function testResolverPicksHighestPriority(async:Async) {
		final dir = Fixture.create({"fake.txt": "", "build.hxml": ""});
		final settings:bridge.Settings.ProjectSettings = {
			providers: [{name: "fake", priority: 100, detect: ["fake.txt"], targets: ["a", "b"], args: {command: Fixture.node("console.log('-D ' + process.argv[1])", ["${target}"])}}]
		};
		ProjectResolver.resolve(Fixture.context(dir, settings), "b").then(function(project) {
			Assert.equals("fake", project.provider);
			Assert.equals("b", project.target); // remembered target
			Assert.same(["-D", "b"], project.args);
			async.done();
		}, error -> fail(async, error));
	}

	@:timeout(10000)
	function testResolverFallsBackWhenProviderFails(async:Async) {
		final dir = Fixture.create({"fake.txt": "", "build.hxml": ""});
		final settings:bridge.Settings.ProjectSettings = {
			providers: [{name: "fake", priority: 100, detect: ["fake.txt"], args: {command: Fixture.node("process.exit(1)")}}]
		};
		ProjectResolver.resolve(Fixture.context(dir, settings), null).then(function(project) {
			Assert.equals("hxml", project.provider);
			Assert.same(["build.hxml"], project.args);
			Assert.equals(1, project.warnings.length);
			async.done();
		}, error -> fail(async, error));
	}

	@:timeout(5000)
	function testResolverDefaultWithoutProjectFiles(async:Async) {
		final dir = Fixture.create({"src/Main.hx": ""});
		ProjectResolver.resolve(Fixture.context(dir), null).then(function(project) {
			Assert.equals("default", project.provider);
			Assert.same(["--class-path", Path.join([dir, "src"])], project.args);
			async.done();
		}, error -> fail(async, error));
	}

	function testCommandProviderTasks() {
		final dir = Fixture.create({"game/project.xml": ""});
		final provider = new CommandProvider({
			name: "fake",
			detect: ["project.xml"],
			buildTypes: {debug: ["-debug"]},
			args: {command: ["true"]},
			tasks: [
				{label: "fake: test ${target}", command: ["fake", "test", "${projectFile}", "${target}", "${buildTypeArgs}"]},
				{label: "fake: clean", command: ["fake", "clean"]}
			]
		});
		final file = Path.join([dir, "game", "project.xml"]);
		final tasks = provider.tasks(Fixture.context(dir, {buildType: "debug"}), file, ["web", "hl"]);
		Assert.same(["fake: test web", "fake: test hl", "fake: clean"], tasks.map(t -> t.label));
		Assert.same(["fake", "test", "project.xml", "web", "-debug"], tasks[0].command);
		Assert.equals(Path.join([dir, "game"]), tasks[0].cwd);
		Assert.equals("web", tasks[0].target);
		Assert.isNull(tasks[2].target);
		Assert.same(["debug", "release"], provider.buildTypes());
	}

	function testHxmlProviderSkipsRunFilesButRunsThem() {
		// Like hx2go: `--run` hands everything after it to the program, the language server's own arguments
		// included, so completion can't use those files. Running them as tasks is fine.
		final dir = Fixture.create({
			"Compile-eval.hxml": "-cp source\n-cp hxb-parser\n--run hx2go.Main",
			"again.hxml": "Compile-eval.hxml",
			"Bootstrap.hxml": "-cp source\n-main hx2go.Main\n-cp hxb-parser\n--custom-target go=output/bootstrap",
			"completion.hxml": "-cp source\n-main hx2go.Main\n-cp hxb-parser\n--no-output\n--custom-target go=output"
		});
		final provider = new HxmlProvider();
		final found = provider.detect(Fixture.context(dir)).map(Path.withoutDirectory);
		Assert.same(["completion.hxml", "Bootstrap.hxml"], found);
		final labels = provider.tasks(Fixture.context(dir), Path.join([dir, "completion.hxml"]), found).map(t -> t.label);
		Assert.same(["haxe: completion.hxml", "haxe: Bootstrap.hxml"], labels.slice(0, 2));
		final runs = labels.slice(2);
		runs.sort(Reflect.compare);
		Assert.same(["haxe: Compile-eval.hxml", "haxe: again.hxml"], runs);
	}

	function testHxmlDebugConfigurations() {
		// Like linc_sdl3's demo: a cppia host (scriptable --cpp), a plain hxcpp build, and a script the host runs.
		final dir = Fixture.create({
			"common.hxml": "-cp ..\n--debug\n-D HXCPP_CPP17",
			"cppia.hxml": "common.hxml\n-cp cppia\n-main Main\n-D scriptable\n--cpp bin/cppia\n--dce no",
			"hxcpp.hxml": "common.hxml\n-cp hxcpp\n-main Main\n--cpp bin/cpp",
			"script.hxml": "common.hxml\n-cp script\n-main Client\n--cppia bin/cppia/script.cppia",
			"orphan.hxml": "-main Client\n--cppia elsewhere/script.cppia",
			"tool.hxml": "-cp src\n--run Tool",
			"neko.hxml": "-main Main\n--neko bin/main.n",
			"eval.hxml": "-main Main\n--interp"
		});
		final provider = new HxmlProvider();
		final ctx = Fixture.context(dir);
		final targets = provider.detect(ctx).map(Path.withoutDirectory);
		final debug = [for (task in provider.tasks(ctx, Path.join([dir, "cppia.hxml"]), targets)) task.label => task.debug];
		Assert.same({hxml: "cppia.hxml"}, debug["haxe: cppia.hxml"]);
		Assert.same({hxml: "hxcpp.hxml"}, debug["haxe: hxcpp.hxml"]);
		Assert.same({hxml: "eval.hxml"}, debug["haxe: eval.hxml"]);
		Assert.same({hxml: "script.hxml", program: "bin/cppia/Main-debug" + exe}, debug["haxe: script.hxml"]);
		// A script no host runs, a --run tool and a target the debugger doesn't handle: tasks, but nothing to debug.
		for (label in ["haxe: orphan.hxml", "haxe: tool.hxml", "haxe: neko.hxml"]) {
			Assert.isTrue(debug.exists(label), label);
			Assert.isNull(debug[label], label);
		}
	}

	function testCppiaHostNamedLikeHxcpp() {
		final dir = Fixture.create({
			"host.hxml": "-main game.Host\n-D scriptable\n--cpp out",
			"named.hxml": "-main game.Host\n-D scriptable\n-D HAXE_OUTPUT_FILE=Game\n--debug\n-D DEBUGSUFFIX=_d\n--cpp named",
			"a.hxml": "-main A\n--cppia out/scripts/a.cppia",
			"b.hxml": "-main B\n--cppia named/b.cppia"
		});
		final provider = new HxmlProvider();
		final ctx = Fixture.context(dir);
		final tasks = provider.tasks(ctx, Path.join([dir, "a.hxml"]), ["a.hxml", "b.hxml"]);
		// A release build has no suffix; the package isn't part of the name.
		Assert.equals("out/Host" + exe, tasks[0].debug?.program);
		Assert.equals("named/Game_d" + exe, tasks[1].debug?.program);
	}

	function testCommandProviderDebugTargets() {
		final dir = Fixture.create({"project.xml": ""});
		final provider = new CommandProvider({
			name: "fake",
			detect: ["project.xml"],
			args: {command: ["true"]},
			tasks: [
				{label: "fake: test ${target}", command: ["fake", "test", "${target}"], debugTargets: ["html5", "${hostPlatform}"]},
				{label: "fake: build ${target}", command: ["fake", "build", "${target}"]}
			]
		});
		final tasks = provider.tasks(Fixture.context(dir), Path.join([dir, "project.xml"]), ["html5", "android", CommandProvider.hostPlatform]);
		final debug = [for (task in tasks) task.label => task.debug];
		Assert.same({command: ["fake", "test", "html5"]}, debug["fake: test html5"]);
		Assert.same({command: ["fake", "test", CommandProvider.hostPlatform]}, debug["fake: test " + CommandProvider.hostPlatform]);
		Assert.isNull(debug["fake: test android"]);
		Assert.isNull(debug["fake: build html5"]);
	}

	static final exe = js.Node.process.platform == "win32" ? ".exe" : "";

	function testHxmlTasksSkipIncludedFiles() {
		final dir = Fixture.create({"common.hxml": "-cp src", "build.hxml": "common.hxml\n--interp"});
		final provider = new HxmlProvider();
		final tasks = provider.tasks(Fixture.context(dir), Path.join([dir, "build.hxml"]), ["build.hxml", "common.hxml"]);
		Assert.same(["haxe: build.hxml"], tasks.map(t -> t.label));
		Assert.same(["haxe", "build.hxml"], tasks[0].command);
	}

	function testTargetChoice() {
		Assert.equals("hl", ProjectResolver.chooseTarget("hl", "html5", ["html5", "hl"]));
		Assert.equals("hl", ProjectResolver.chooseTarget(null, "hl", ["html5", "hl"]));
		Assert.equals("html5", ProjectResolver.chooseTarget(null, "gone", ["html5", "hl"]));
		Assert.isNull(ProjectResolver.chooseTarget(null, null, []));
	}

	static function fail(async:Async, error:Dynamic) {
		Assert.fail(Std.string(error));
		async.done();
	}
}

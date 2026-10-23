import bridge.toolchain.Haxerc;
import bridge.toolchain.Resolvers;
import bridge.toolchain.Toolchain;
import bridge.toolchain.ToolchainResolver.ToolchainContext;
import haxe.DynamicAccess;
import haxe.io.Path;
import js.Node.process;
import utest.Assert;

/** Choosing the Haxe executable: .haxerc, haxe-manager, lix, PATH and settings. **/
class ToolchainTest extends utest.Test {
	function testHaxercIsFoundInParentFolders() {
		final dir = Fixture.create({".haxerc": '{"version": "4.3.7", "resolveLibs": "scoped"}', "game/src/Main.hx": ""});
		final found = Haxerc.find(Path.join([dir, "game"]), dir);
		Assert.equals("4.3.7", found?.data.version);
		Assert.equals("scoped", found?.data.resolveLibs);
		Assert.isNull(Haxerc.find(Path.join([dir, "game"]), Path.join([dir, "game"])));
	}

	function testHaxeManagerVersionNames() {
		final root = haxeManager();
		Assert.equals(Path.join([root, "versions", "4.3.7"]), HaxeManagerResolver.findVersion(root, "4.3.7"));
		Assert.equals(Path.join([root, "releases", "haxe_20261019195531_066bd83"]), HaxeManagerResolver.findVersion(root, "066bd83"));
		Assert.equals(Path.join([root, "versions", "5.0.0-preview.1+abc1234"]), HaxeManagerResolver.findVersion(root, "abc1234"));
		Assert.isNull(HaxeManagerResolver.findVersion(root, "9.9.9"));
	}

	function testHaxeManagerResolvesHaxercVersion() {
		final root = haxeManager();
		final notes = [];
		final choice = new HaxeManagerResolver().resolve(context(root, {version: "4.3.7"}), notes);
		Assert.equals(Path.join([root, "versions", "4.3.7", "haxe"]), choice?.path);
		Assert.equals(Path.join([root, "versions", "4.3.7", "std"]), choice?.env?.get("HAXE_STD_PATH"));

		Assert.isNull(new HaxeManagerResolver().resolve(context(root, {version: "9.9.9"}), notes));
		Assert.stringContains("hx download 9.9.9", notes.join("\n"));
	}

	function testLixUsesProjectShim() {
		final dir = Fixture.create({".haxerc": '{"version": "4.3.7"}'});
		final shim = Fixture.script(dir, "node_modules/.bin/haxe", "echo 4.3.7");
		Assert.equals(shim, new LixResolver().resolve(context(dir, {version: "4.3.7"}), [])?.path);
		Assert.isNull(new LixResolver().resolve(context(dir, null), []));
	}

	function testOrderAndOverrides() {
		final dir = Fixture.create({});
		final haxe = Fixture.script(dir, "bin/haxe", "echo 4.3.7");
		final ctx = context(dir, null, "/from/provider/haxe");

		// The provider's Haxe (e.g. Ceramic's) wins by default...
		Assert.equals("/from/provider/haxe", Toolchain.resolve(ctx, {}).path);
		// ...unless "provider" is left out of the order,
		final fromPath = Toolchain.resolve(ctx, {haxeResolvers: ["path"]});
		Assert.equals(haxe, fromPath.path);
		Assert.equals("path", fromPath.source);
		Assert.equals("4.3.7", fromPath.version);
		Assert.equals(4, fromPath.major);
		// ...and an explicit path beats everything.
		Assert.equals("/explicit/haxe", Toolchain.resolve(ctx, {haxePath: "/explicit/haxe"}).path);
		// Unknown names are reported.
		Assert.stringContains("nope", Toolchain.resolve(ctx, {haxeResolvers: ["nope", "path"]}).notes.join("\n"));
	}

	function testCommandResolverFromSettings() {
		final dir = Fixture.create({"tool.cfg": ""});
		final result = Toolchain.resolve(context(dir, null), {
			resolvers: [{name: "mytool", detect: ["tool.cfg"], command: Fixture.node("console.log('/opt/mytool/haxe')")}],
			haxeResolvers: ["mytool"]
		});
		Assert.equals("/opt/mytool/haxe", result.path);
		Assert.equals("mytool", result.source);
	}

	function testHaxe3VersionIsRead() {
		final dir = Fixture.create({});
		// Haxe 3 rejects --version and prints -version on stderr.
		final haxe = Fixture.script(dir, "bin/haxe", 'if [ "$$1" = "-version" ]; then echo 3.4.7 >&2; else exit 1; fi');
		final resolved = Toolchain.resolve(context(dir, null, null), {haxePath: haxe});
		Assert.equals("3.4.7", resolved.version);
		Assert.equals(3, resolved.major);
	}

	function testSiblingStdIsUsed() {
		final dir = Fixture.create({"haxe/std/StdTypes.hx": ""});
		final haxe = Fixture.script(dir, "haxe/haxe", "echo 4.3.7");
		final result = Toolchain.resolve(context(dir, null), {haxePath: haxe});
		Assert.equals(Path.join([dir, "haxe", "std"]), result.env.get("HAXE_STD_PATH"));
	}

	/** A fake haxe-manager install with an `hx` launcher in bin/. **/
	static function haxeManager():String {
		final root = Fixture.create({
			"versions/4.3.7/std/StdTypes.hx": "",
			"versions/5.0.0-preview.1+abc1234/std/StdTypes.hx": "",
			"releases/haxe_20261019195531_066bd83/std/StdTypes.hx": ""
		});
		Fixture.script(root, "bin/hx", "true");
		Fixture.script(root, "versions/4.3.7/haxe", "echo 4.3.7");
		return root;
	}

	static function context(dir:String, haxerc:Null<HaxercData>, ?providerHaxePath:String):ToolchainContext {
		final env:DynamicAccess<String> = process.env.copy();
		env.set("PATH", Path.join([dir, "bin"]));
		return {
			workspaceRoot: dir,
			projectRoot: dir,
			haxerc: haxerc,
			providerHaxePath: providerHaxePath,
			env: env
		};
	}
}

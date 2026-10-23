import haxe.Json;

class Broken {
	public static function run() {
		var count:Int = "not a number";
		return missingFunction(count);
	}
}

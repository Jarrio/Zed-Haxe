package bridge.util;

/**
	Prints types from the compiler's JSON display protocol (`haxe.display.JsonModuleTypes.JsonType`)
	the way they are written in Haxe: `Array<String>`, `(a:Int, ?b:Bool) -> Void`, `{ x:Float }`.
**/
class HaxeTypes {
	public static function print(type:Dynamic):String {
		if (type == null) {
			return "?";
		}
		final args:Dynamic = type.args;
		return switch (type.kind : String) {
			case "TInst" | "TEnum" | "TType" | "TAbstract":
				final params:Array<Dynamic> = args.params ?? [];
				args.path.typeName + (params.length == 0 ? "" : "<" + params.map(print).join(", ") + ">");
			case "TFun":
				final parameters:Array<Dynamic> = args.args ?? [];
				"(" + parameters.map(argument -> (argument.opt ? "?" : "") + (argument.name != "" ? argument.name + ":" : "") + print(argument.t)).join(", ")
					+ ") -> " + print(args.ret);
			case "TAnonymous":
				final fields:Array<Dynamic> = args.fields ?? [];
				"{ " + fields.map(field -> field.name + ":" + print(field.type)).join(", ") + " }";
			case "TDynamic":
				args == null ? "Dynamic" : "Dynamic<" + print(args) + ">";
			case _:
				"?";
		}
	}
}

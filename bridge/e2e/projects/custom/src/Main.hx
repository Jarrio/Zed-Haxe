import pack.Shape;

class Main {
	static function main() {
		#if (custom_target == "b")
		final onTargetB = true;
		#else
		final onTargetA = true;
		#end
		final circle = new Circle(2);
		trace(circle.area());
	}
}

class Circle implements Shape {
	public var name(default, null) = "circle";
	final radius:Float;

	public function new(radius:Float) {
		this.radius = radius;
	}

	public function area():Float {
		return Math.PI * radius * radius;
	}
}

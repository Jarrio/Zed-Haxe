import pack.Shape;

class Main {
	static function main() {
		final circle = new Circle(2);
		trace(circle.area());
		final shape:Shape = circle;
		trace(shape.name);
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

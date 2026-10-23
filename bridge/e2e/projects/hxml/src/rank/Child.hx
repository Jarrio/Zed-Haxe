package rank;

/** A class that ranks things; the word class appears in this doc comment. **/
class Child extends Base {
	public var shown:Int = 0;
	var mySecret:Int = 0;
	var _myCache:Int = 0;

	/** Works on the class of things. **/
	function work() {
		trace("toplevel");
		trace("dot");
	}

	function _myHelper() {}
}

class Sibling {
	var siblingSecret:Int = 0;

	public function new() {}

	function check(child:Child) {
		trace("sibling");
	}
}

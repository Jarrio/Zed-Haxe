import utest.Runner;
import utest.ui.Report;

class TestMain {
	static function main() {
		bridge.Log.install();
		final runner = new Runner();
		runner.addCase(new BasicsTest());
		runner.addCase(new ProvidersTest());
		runner.addCase(new ToolchainTest());
		runner.addCase(new RewritesTest());
		runner.addCase(new MarkupTest());
		runner.addCase(new WindowsTest());
		runner.onComplete.add(_ -> Fixture.removeAll());
		Report.create(runner);
		runner.run();
	}
}

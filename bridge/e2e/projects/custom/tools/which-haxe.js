// Pretend toolchain manager: prints the Haxe to use (the one e2e/run.js was given, else haxe on PATH).
console.log(process.env.E2E_HAXE || "haxe");

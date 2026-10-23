// Pretend framework CLI: prints display arguments for a target as JSON.
const target = process.argv[2] || "a";
console.log(JSON.stringify({ args: ["-cp", "src", "-main", "Main", "-D", "custom_target=" + target, "--interp"], watch: ["custom.project"] }));

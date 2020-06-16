import std.stdio;

import arc.compiler;

int do_cli(string[] args) {
	auto compiler = new Compiler();

	compiler.compile(args[1 .. $], CompileOptions());

	if (compiler.reporter.errors.length > 0)
		return -compiler.reporter.errors[0].code;
	return 0;
}

int main(string[] args) {
	// return do_cli(args);
	// return do_cli(["", "lexer.arc"]);
	import tests.arc.collect_info;
	test();
	return 0;
}

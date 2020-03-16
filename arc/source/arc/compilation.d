/**
 * Data required for compilation 
 */
module arc.compilation;

/**
 * A shared structure for data that is required at every phase of the 
 * compilation process. It is designed to be as small as possible, so that it
 * may be passed between each stage of compilation.
 *
 * This includes things like access to the other files in the compilation,
 * error handling faciliites, and memory management.
 *
 * Notably, this excludes anything to do with threading, file loading, and other
 * such facilities.
 */
final class Compilation {
    import arc.stringtable: StringTable;
    import arc.source: SourceMap, Source, Span;
    import arc.reporting: ArcError, ArcWarning;
    import arc.syntax.ast: AstNode;

    SourceMap sources;
    StringTable strings;
    ArcError[] errors;
    ArcWarning[] warnings;

    // For a compilation that manages its own sources and string table
    this() {
        sources = new SourceMap();
        strings = new StringTable();
    }

    void error(Args...)(ArcError.Code error_code, Span span, string message, Args args) {
        errors ~= ArcError(
            error_code,
            span.start,
            tprint(message, args).idup
        );
    }

    void warning(Args...)(ArcWarning.Code warn_code, Span span, string message, Args args) {
        warnings ~= ArcWarning(
            warn_code,
            span.start,
            tprint(message, args).idup
        );
    }

    AstNode parse(Source source) {
        import std.stdio: writefln;
        import arc.syntax.parser: ParseCtx, parse_module;

        auto ctx = ParseCtx(this, source.text, source.start_offset);
        auto result = parse_module(ctx);

        if (warnings.length > 0) {
            foreach (warning; warnings) {
                const coords = source.get_loc(warning.location);
                writefln(
                    "Warning:\n%s\nAt %s line %s column %s\n",
                    warning.message,
                    source.name,
                    coords.line,
                    coords.column
                );
            }
        }

        if (errors.length > 0) {
            foreach (error; errors) {
                const coords = source.get_loc(error.location);
                writefln(
                    "Error:\n%s\nAt %s line %s column %s\n",
                    error.message,
                    source.name,
                    coords.line,
                    coords.column
                );
            }

            return null;
        }

        return result;
    }
}

const(char[]) tprint(Args...)(string message, Args args) {
    import std.format: formattedWrite;

    static struct Buffer {
        char[] data;
        size_t length;

        void put(char c) {
            assert(length < data.length);
            data[length] = c;
            length++;
        }

        const(char[]) text() const { return data[0 .. length]; }
    }

    static char[4096] temp_buffer;

    auto buffer = Buffer(temp_buffer);
    formattedWrite(buffer, message, args);
    
    return buffer.text();
}

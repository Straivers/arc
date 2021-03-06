module tests.arc.lexer;

import arc.data.span: Span;
import arc.data.hash: hash_of;
import arc.data.stringtable: StringTable;
import arc.analysis.lexer: Token, TokenBuffer;

/// Thread-local global token buffer so we don't have to allocate a whole bunch
/// of these. Also makes the interface of `scan_tokens(text)` simpler.
Token[64] token_buffer;

/// Read all tokens from text, up to `token_buffer.length`.
Token[] scan_tokens(const(char)[] text) {
    // IMPORTANT: strings is a throwaway value used only to facilitate lexing
    StringTable strings;
    auto stream = TokenBuffer(text, token_buffer, &strings);
    return stream.buffer[];
}

/// Tests that the tokens provided are equivalent in type or value to `ts`.
bool equivalent(bool compare_type = true, T)(Token[] tokens, T[] ts...) {
    import std.algorithm: equal, map;
    import std.range: zip;
    import std.format: format;

    size_t length;
    for (; tokens[length].type != Token.Type.Done && length < tokens.length; length++) {}

    static if (compare_type)
        return tokens[0 .. length].map!(a => a.type).equal(ts);
    else
        return tokens[0 .. length].equal(ts);
}

@("Lex Empty") unittest {
    assert("".scan_tokens[0].type == Token.Type.Done);
}

@("Lex Whitespace") unittest {
    assert("  \t\t\t\t    ".scan_tokens[0].type == Token.Type.Done);
}

@("Lex Line Comment") unittest {

    assert("#blah blah blah".scan_tokens[0].type == Token.Type.Done);
    assert("#blah\n#blah".scan_tokens[0].type == Token.Type.Done);

    // import std.stdio; writeln("#asflj".scan_tokens[0].span);
}

@("Lex Compact") unittest {
    assert("()[]{},.;->=>1a_3".scan_tokens.equivalent(
        Token.Type.Lparen,
        Token.Type.Rparen,
        Token.Type.Lbracket,
        Token.Type.Rbracket,
        Token.Type.Lbrace,
        Token.Type.Rbrace,
        Token.Type.Comma,
        Token.Type.Dot,
        Token.Type.Semicolon,
        Token.Type.RArrow,
        Token.Type.RFatArrow,
        Token.Type.TokInteger,
        Token.Type.TokName,
    ));
}

@("Lex Operators") unittest {
    assert("+ - * / ^ & < > = ! <= != >=".scan_tokens.equivalent(
        Token.Type.Plus,
        Token.Type.Minus,
        Token.Type.Star,
        Token.Type.Slash,
        Token.Type.Caret,
        Token.Type.Ampersand,
        Token.Type.Less,
        Token.Type.Greater,
        Token.Type.Equals,
        Token.Type.Bang,
        Token.Type.LessEqual,
        Token.Type.BangEqual,
        Token.Type.GreaterEqual
    ));
}

@("Lex Keywords") unittest {
    assert("and or if else loop break return continue def".scan_tokens.equivalent!false(
        Token(Token.Type.TokAnd,        Span(0, 3), hash_of("and")),
        Token(Token.Type.TokOr,         Span(4, 2), hash_of("or")),
        Token(Token.Type.TokIf,         Span(7, 2), hash_of("if")),
        Token(Token.Type.TokElse,       Span(10, 4), hash_of("else")),
        Token(Token.Type.TokLoop,       Span(15, 4), hash_of("loop")),
        Token(Token.Type.TokBreak,      Span(20, 5), hash_of("break")),
        Token(Token.Type.TokReturn,     Span(26, 6), hash_of("return")),
        Token(Token.Type.TokContinue,   Span(33, 8), hash_of("continue")),
        Token(Token.Type.TokDef,        Span(42, 3), hash_of("def"))
    ));
}

@("Lex Char") unittest {
    assert("'a'".scan_tokens.equivalent(Token.Type.TokChar));
    assert("'\\a'".scan_tokens.equivalent!false(
        Token(Token.Type.TokChar, Span(0, 4), hash_of("\\a"))
    ));
}

@("Lex String") unittest {
    assert(`"hello world"`.scan_tokens.equivalent(Token.Type.TokString));
    assert(`"\""`.scan_tokens.equivalent(Token.Type.TokString));
}

@("Lex Integers") unittest {
    assert("20".scan_tokens()[0].value == 20);
    assert("1_____23__4___".scan_tokens()[0].value == 1234);
    assert("3b".scan_tokens.equivalent(Token.Type.TokInteger, Token.Type.TokName));
}

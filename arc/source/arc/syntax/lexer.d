module arc.syntax.lexer;

/**
 * A Token is the smallest discrete unit that represents useful information in
 * an Arc program.
 *
 * Note that this token representation does not know where it came from. That is
 * the responsibility of higher-level modules to keep track of.
 */
struct Token {
    /**
     * Every token has a type, which informs the parser how it needs to process
     * the token into a useful representation of an analyzed piece of code
     * called an abstract syntax tree (AST).
     */
    enum Type: ubyte {
        Invalid, Eof, Eol = '\n',
        Name, Integer,

        Lparen = '(', Rparen = ')',
        Lbracket = '[', Rbracket = ']',
        Comma = ',', Dot = '.', Semicolon = ';', Colon = ':',
        Plus = '+', Minus = '-', Slash = '/', Star = '*', Caret = '^',
        Equals = '=',
        Rarrow,
    }

    alias Type this;

    /// The type classification of the token
    Type type;
    /// A permanent pointer to the first character in this token
    const(char)* start;
    /// The length of the token in bytes
    size_t span;
}

/**
 * Input: Contiguous memory region containing arbitrary data.
 * Output: Sequence of classified sections of the arbitrary data.
 */
struct Lexer {
    import std.container.array: Array;

    /// A pointer to the current character in the source text
    const(char)* source_text;
    /// A pointer to the end of the source text
    const(char)* end_of_text;
    /// The ID with which the source text may be referred to
    /// The most recently analyzed token
    Token next, current;

    Array!(Token.Type) eol_type_stack;

    /**
     * Sets up the lexer to analyze a new source document
     */
    void reset(const(char)[] source) {
        source_text = source.ptr;
        end_of_text = source.ptr + source.length;
        eol_type_stack.clear();
    }

    void ready() {
        advance();
        advance();
    }

    void push_eol_type(Token.Type t) {
        eol_type_stack.insertBack(t);
    }

    void pop_eol_type() {
        eol_type_stack.removeBack();
    }

    void advance() {
        if (next.type == Token.Eol) {
            switch (current.type) with (Token.Type) {
            case Rparen:
            case Rbracket:
            case Name:
            case Integer:
                current = Token(eol_type_stack.back, next.start, 0);
                break;
            default:
                do {
                    current = next;
                    next = scan_token();
                } while (current.type == Token.Eol);
            }
        }
        else {
            current = next;
            next = scan_token();
        }
    }

    Token scan_token() {
        auto start = source_text;

        switch_start:
        if (source_text >= end_of_text) {
            return Token(Token.Eof, source_text, 0);
        }

        // A switch statement with label/goto was the simplest way to start.
        // @Optimize A character-table driven approach may be more performant.
        switch (*source_text) {
            case ' ':
            case '\t':
            case '\r':
                source_text++;
                start++;
                goto switch_start;
            case '\n':
                source_text++;
                return Token(Token.Eol, start, 1);
            case '(':
                source_text++;
                return Token(Token.Lparen, start, 1);
            case ')':
                source_text++;
                return Token(Token.Rparen, start, 1);
            case '[':
                source_text++;
                return Token(Token.Lbracket, start, 1);
            case ']':
                source_text++;
                return Token(Token.Rbracket, start, 1);
            case ',':
                source_text++;
                return Token(Token.Comma, start, 1);
            case '.':
                source_text++;
                return Token(Token.Dot, start, 1);
            case ';':
                source_text++;
                return Token(Token.Semicolon, start, 1);
            case ':':
                source_text++;
                return Token(Token.Colon, start, 1);
            case '+':
                source_text++;
                return Token(Token.Plus, start, 1);
            case '-':
                source_text++;
                if (*source_text == '>') {
                    source_text++;
                    return Token(Token.Rarrow, start, 2);
                }
                else {
                    return Token(Token.Minus, start, 1);
                }
            case '*':
                source_text++;
                return Token(Token.Star, start, 1);
            case '/':
                source_text++;
                return Token(Token.Slash, start, 1);
            case '^':
                source_text++;
                return Token(Token.Caret, start, 1);
            case '=':
                source_text++;
                return Token(Token.Equals, start, 1);
            case 'a': .. case 'z':
            case 'A': .. case 'Z':
            case '_':
                source_text++;
                name_start:
                switch (*source_text) {
                    case 'a': .. case 'z':
                    case 'A': .. case 'Z':
                    case '0': .. case '9':
                    case '_':
                        source_text++;
                        goto name_start;
                    default:
                }

                return Token(Token.Name, start, source_text - start);
            case '0': .. case '9':
                source_text++;
                while (('0' <= *source_text && *source_text <= '9') || *source_text == '_')
                    source_text++;
                // We have to traverse the integer again in the parser
                // Yes, this is not exactly efficient. No, it doesn't really
                // matter right now
                return Token(Token.Integer, start, source_text - start);
            default:
                source_text++;
                current = Token(Token.Invalid, start, source_text - start);
        }

        // This part is to handle invalid tokens that fall through to switch::default
        if (next.type == Token.Invalid) goto switch_start;
        return current;
    }
}


version(unittest) {
    Lexer lex(const(char)[] src) {
        Lexer lexer;
        lexer.reset(src);
        return lexer;
    }
}

// Test empty lexer
unittest {
    auto lexer = lex("");
    assert(lexer.current.type == Token.Invalid);
    assert(lexer.scan_token.type == Token.Eof);
}

// Test empty lexer with whitespace
unittest {
    assert(lex("  \r\t\t\t\t    ").scan_token.type == Token.Eof);
}

// Test isolated tokens
unittest {
    import std.range: zip;

    const strings = ["(", ")", "[", "]", ",", ".", ";", "->", "129400_81", "anb_wo283"];
    const types = [Token.Lparen, Token.Rparen, Token.Lbracket, Token.Rbracket, Token.Comma, Token.Dot, Token.Semicolon, Token.Rarrow, Token.Integer, Token.Name];
    assert(strings.length == types.length);

    foreach (pair; zip(strings, types)) {
        auto t = lex(pair[0]).scan_token;
        assert(t.type == pair[1] && t.start[0 .. t.span] == pair[0]);
    }
}

// Test adjescent tokens
unittest {
    const str = "[[]]],19281_2918 (_aiw19)_";
    const types = [
        Token.Lbracket, Token.Lbracket,Token.Rbracket, Token.Rbracket, Token.Rbracket, Token.Comma,
        Token.Integer, Token.Lparen, Token.Name, Token.Rparen, Token.Name
    ];

    auto lexer = lex(str);
    foreach (i; 0 .. types.length) {
        assert(lexer.scan_token.type == types[i]);
    }

    assert(lexer.scan_token.type == Token.Eof);
}

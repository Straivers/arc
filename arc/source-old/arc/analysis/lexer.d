module arc.analysis.lexer;

import arc.data.hash : hash_of, Hash;
import arc.data.span;
import arc.data.stringtable: StringTable;
import arc.util : case_of;

/// A `Token` is the smallest discrete unit of the source text that the compiler
/// operates on.
struct Token {
    /// Represents the distinct classes of tokens that the are used in the compiler.
    enum Type : ubyte {
        // dfmt off
        None, Invalid, Done,

        Lparen = '(', Rparen = ')', Lbracket = '[', Rbracket = ']', Lbrace = '{', Rbrace = '}',
        Comma = ',', Dot = '.', Semicolon = ';', Colon = ':',
        Ampersand = '&', Plus = '+', Minus = '-', Slash = '/', Star = '*', Caret = '^',
        Equals = '=', Less = '<', Greater = '>', Bang = '!',
        LessEqual = 128, GreaterEqual, EqualEqual, BangEqual,
        RArrow, RFatArrow, ColonColon,
        
        TokName, TokInteger, TokChar, TokString,

        TokAnd, TokOr, TokNot,
        TokIf, TokElse, TokLoop, TokBreak, TokReturn, TokContinue,
        TokDef, TokImport,
        // dfmt on
    }

    ///
    Type type;
    ///
    Span span;
    union {
        ///
        Hash key;
        ///
        ulong value;
    }

    bool opCast(T: bool)() { return type != Type.None; }
}

/// Returns `true` if `type` matches one of the types in `types`.
bool matches_one(Token.Type type, const Token.Type[] types...) {
    foreach (t; types)
        if (type == t)
            return true;
    return false;
}

/**
 A TokenBuffer offers a buffered 1-token window over a source text.
 */
struct TokenBuffer {
private:
    size_t _current_token_index;
    size_t _next_buffer_index;
    StringTable* _stringtable;

public:
    Token[] buffer;
    const(char)[] source_text;
    Token current;
    bool done;

    alias token = current;

    this(const(char)[] text, Token[] tokens, StringTable* stringtable) {
        source_text = text;
        _stringtable = stringtable;
        buffer = tokens;
        fill_buffer();
        advance();
    }

    void advance() {
        current = buffer[_current_token_index];
        done = current.type == Token.Type.Done;
        _current_token_index++;

        if (_current_token_index == buffer.length)
            fill_buffer();
    }

    Token next() {
        return buffer[_current_token_index];
    }

    void fill_buffer() {
        const base = source_text.ptr;
        auto current = source_text.ptr + _next_buffer_index; // we allow indexing past the buffer because scan_token handles it for us.
        const end = source_text.length + base;

        debug buffer[] = Token.init;

        // get first token, might be Done
        buffer[0] = scan_token(base, current, end, _stringtable);
        for (size_t i = 1; buffer[i - 1].type != Token.Type.Done && i < buffer.length;
                i++)
            buffer[i] = scan_token(base, current, end, _stringtable);

        const read = current - (source_text.ptr + _next_buffer_index);
        _next_buffer_index += read;
        _current_token_index = 0;
    }
}

private:

/// Hashmap of reserved keywords and their corresponding token types
immutable Token.Type[Hash] keywords;

shared static this() {
    keywords[hash_of("and")] = Token.Type.TokAnd;
    keywords[hash_of("or")] = Token.Type.TokOr;
    keywords[hash_of("not")] = Token.Type.TokNot;
    keywords[hash_of("if")] = Token.Type.TokIf;
    keywords[hash_of("else")] = Token.Type.TokElse;
    keywords[hash_of("loop")] = Token.Type.TokLoop;
    keywords[hash_of("break")] = Token.Type.TokBreak;
    keywords[hash_of("return")] = Token.Type.TokReturn;
    keywords[hash_of("continue")] = Token.Type.TokContinue;
    keywords[hash_of("def")] = Token.Type.TokDef;
    keywords[hash_of("import")] = Token.Type.TokImport;
}

/**
 Identifies the first valid token in the text sequence from `*current` to
 `end`. If the first character in the text is not a valid start of a token, a
 token of type `Invalid` will be returned. Note that this function does no
 currently process multiple `Invalid` characters as a single token.

 This function will identify keywords as distinct from symbols.
 */
Token scan_token(const char* base, ref const(char)* current, ref const(char*) end, StringTable* stringtable) {
    auto start = current;

    auto final_span() {
        return Span(cast(uint) (start - base), cast(uint) (current - start));
    }

    auto make_token(Token.Type t, size_t advance_n, Hash key = Hash(0)) {
        current += advance_n;
        return Token(t, final_span(), key);
    }

    auto make_2_op(char second, Token.Type two_char_type, Token.Type one_char_type) {
        static const length = [2, 1];
        Token.Type[2] ttype = [two_char_type, one_char_type];
        const is_single_char = (current + 1 == end) | (*(current + 1) != second); //bit to avoid short circuit
        return make_token(ttype[is_single_char], length[is_single_char]);
    }

    while (start < end) {
        current = start;

        switch (*current) with (Token.Type) {
        case '#':
            while (start < end && *start != '\n')
                start++;
            start++; // we can safely cross past end, handled in loop conditional
            continue;

        // dfmt off
        mixin(case_of(" \t\r\n"));
            start++;
            continue;

        mixin(case_of("()[]{}.,;+*^&/"));
            return make_token(cast(Token.Type)*current, 1);

        case ':': return make_2_op(':', ColonColon,     Colon);
        case '-': return make_2_op('>', RArrow,         Minus);
        case '<': return make_2_op('=', LessEqual,      Less);
        case '>': return make_2_op('=', GreaterEqual,   Greater);
        case '!': return make_2_op('=', BangEqual,      Bang);
        // dfmt on

        case '=':
            current++;
            if (*current == '=')
                return make_token(EqualEqual, 1);
            else if (*current == '>')
                return make_token(RFatArrow, 1);
            else
                return make_token(Equals, 0);

        case '\'':
            current++;
            const length = *current == '\\' ? 2 : 1;
            const key = stringtable.intern(current[0 .. length]);

            if (current < end && *(current + length) == '\'')
                return make_token(TokChar, length + 1, key);
            return make_token(Invalid, current - start);

        case '"':
            current++;
            for (; current < end; current++) {
                const c = *current;
                if (c == '\\')
                    current++;
                if (c == '"')
                    break;
            }

            const length = current - start;
            if (current == end)
                make_token(Invalid, length);
            return make_token(TokString, 1, stringtable.intern(start[0 .. length]));

        case 'a': .. case 'z':
        case 'A': .. case 'Z':
        case '_':
        loop: for (; current < end; current++) switch (*current) {
            case 'a': .. case 'z':
            case 'A': .. case 'Z':
            case '0': .. case '9':
            case '_':
                continue;
            default:
                break loop;
            }

            const key = stringtable.intern(start[0 .. current - start]);
            const type = keywords.get(key, TokName);
            return make_token(type, 0, key);

        case '0': .. case '9':
            while (current < end && (('0' <= *current
                    && *current <= '9') || *current == '_'))
                current++;
            auto token = make_token(TokInteger, 0);
            token.value = string_to_int(start[0 .. current - start]);
            return token;

        default:
            return make_token(Invalid, 1);
        }
    }

    return Token(Token.Type.Done, Span(cast(uint)(end - base), 0));
}

ulong string_to_int(const char[] text) {
    ulong value = text[0] - '0';

    foreach (c; text[1 .. $]) {
        if (c == '_')
            continue;
        value = value * 10 + (c - '0');
    }

    return value;
}

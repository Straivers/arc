module arc.syntax.parser;

import std.container.array: Array;

import arc.hash: Key;
import arc.stringtable: StringTable;
import arc.syntax.ast: AstNode;
import arc.syntax.lexer: Cursor, Token, matches_one, scan_token, initialize_token_strings;
import arc.source: Span, merge, merge_all;
import arc.syntax.reporting: SyntaxError, SyntaxWarning;

enum Precedence {
    None,
    Assign,
    Logic,
    Equality,
    Compare,
    Sum,
    Product,
    Power,
    Call,
    Primary
}

enum max_errors = 20;

struct ParseCtx {
    Cursor cursor;
    uint span_offset;

    Token current;

    StringTable strings;
    Array!(Token.Type) delimiter_stack;

    SyntaxError[] errors;
    SyntaxWarning[] warnings;

    this(const(char)[] source, uint span_offset, StringTable strings) {
        cursor = Cursor(source);
        this.span_offset = span_offset;
        this.strings = strings;
        initialize_token_strings(strings);
        advance();
    }

    bool done() {
        return current.type == Token.Done;
    }

    void advance() {
        const delimiter = delimiter_stack.length > 0 ? delimiter_stack.back : Token.Invalid;
        current = scan_token(cursor, current.type, delimiter , strings);
        current.span.start += span_offset;
    }

    Token take_token() {
        auto token = current;
        advance();
        return token;
    }

    void error(Args...)(SyntaxError.Code error_code, string message, Args args) {
        errors ~= SyntaxError(
            error_code,
            current.span.start,
            tprint(message, args).idup
        );
    }

    void warning(Args...)(SyntaxWarning.Code warn_code, string message, Args args) {
        warnings ~= SyntaxWarning(
            warn_code,
            current.span.start,
            tprint(message, args).idup
        );
    }

    bool skip_token(Token.Type type) {
        if (current.type != type)
            return false;
        advance();
        return true;
    }

    void free(AstNode[] nodes...) {
        import std.algorithm: filter;

        foreach (node; nodes.filter!(a => !a.is_marker)) {
            free(node.get_children());
            destroy(node);
        }
    }

    /// Constructs an array from a comma-separated list of nodes
    AstNode[] node_array(AstNode[] nodes...) {
        return nodes.dup;
    }
}

AstNode parse_module(ref ParseCtx ctx) {
    ctx.delimiter_stack.insertBack(Token.Semicolon);

    AstNode[] statements;
    while (!ctx.done && ctx.errors.length < max_errors)
        statements ~= parse_statement(ctx);

    ctx.delimiter_stack.removeBack();

    if (ctx.errors.length == max_errors && !ctx.done) {
        ctx.warning(
            SyntaxWarning.TooManyErrors,
            "Too many errors were detected in this file. Aborting parse in case of degenerate error."
        );
    }

    return new AstNode(AstNode.Module, Span(ctx.span_offset, cast(uint) ctx.cursor.text.length), statements);
}

AstNode parse_statement(ref ParseCtx ctx) {
    AstNode result;
    switch (ctx.current.type) {
        case Token.If:
            return parse_if(ctx);
        
        case Token.Else:
            ctx.error(
                SyntaxError.UnboundElse,
                "An else-clause must be bound to an if statement."
            );
            const token_span = ctx.take_token().span;
            auto else_body = parse_else(ctx);
            const span = token_span.merge(else_body.span);
            ctx.free(else_body);
            return new AstNode(AstNode.Invalid, span);

        case Token.Loop:
            return parse_loop(ctx);

        case Token.Def:
            result = parse_def(ctx);
            break;

        case Token.Break:
            result = parse_escape!(AstNode.Break, Token.Break, false)(ctx);
            break;
        
        case Token.Return:
            result = parse_escape!(AstNode.Return, Token.Return, true)(ctx);
            break;
        
        case Token.Continue:
            result = parse_escape!(AstNode.Continue, Token.Continue, false)(ctx);
            break;
        
        case Token.Semicolon:
            ctx.warning(
                SyntaxWarning.LonelySemicolon,
                "A semicolon should not be used to indicate an empty statement. Use an empty block instead ({})."
            );
            return new AstNode(AstNode.Block, ctx.take_token().span);

        default:
            result = parse_expression(ctx);
    }

    if (ctx.current.type == Token.Semicolon)
        ctx.advance();
    else if (result.type == AstNode.Invalid)
        return result;
    else {
        auto to_free = result;
        result = new AstNode(AstNode.Invalid, to_free.span);
        ctx.free(to_free);

        ctx.error(
            SyntaxError.TokenExpectMismatch,
            "%ss must terminate in a semicolon.",
            result.type
        );
    }

    return result;
}

AstNode parse_expression(ref ParseCtx ctx, Precedence precedence = Precedence.Assign) {
    auto expression = prefix_parselets[ctx.current.type](ctx);

    while (precedence <= infix_parselets[ctx.current.type].precedence)
        expression = infix_parselets[ctx.current.type].parselet(ctx, expression);

    return expression;
}

AstNode parse_type(ref ParseCtx ctx, Precedence precedence = Precedence.Call) {
    auto expression = get_type_prefix_parselet(ctx.current.type)(ctx);

    while (precedence <= get_type_infix_parselet(ctx.current.type).precedence)
        expression = get_type_infix_parselet(ctx.current.type).parselet(ctx, expression);

    return expression;
}

private:

// ----------------------------------------------------------------------
//    _____  _          _                                 _        
//   / ____|| |        | |                               | |       
//  | (___  | |_  __ _ | |_  ___  _ __ ___    ___  _ __  | |_  ___ 
//   \___ \ | __|/ _` || __|/ _ \| '_ ` _ \  / _ \| '_ \ | __|/ __|
//   ____) || |_| (_| || |_|  __/| | | | | ||  __/| | | || |_ \__ \
//  |_____/  \__|\__,_| \__|\___||_| |_| |_| \___||_| |_| \__||___/
//
// ----------------------------------------------------------------------

AstNode parse_def(ref ParseCtx ctx) {
    const start_span = ctx.take_token().span;

    auto name = parse_key_type!(AstNode.Name)(ctx);

    if (!ctx.skip_token(Token.Colon)) {
        ctx.error(
            SyntaxError.TokenExpectMismatch,
            "A definition must have a type specifier (:)."
        );

        auto result = new AstNode(AstNode.Invalid, merge(start_span, name.span));
        ctx.free(name);
        return result;
    }

    auto type = ctx.current.type != Token.Equals ?
                parse_type(ctx) :
                AstNode.inferred_type;

    auto value = ctx.skip_token(Token.Equals) ?
                 parse_expression(ctx) :
                 AstNode.none;

    const span = merge_all(start_span, name.span, type.span, value.span);
    return new AstNode(AstNode.Define, span, ctx.node_array(name, type, value));
}

AstNode parse_var(ref ParseCtx ctx, AstNode lhs) {
    ctx.advance();

    assert(lhs.type == AstNode.Name);

    auto type = ctx.current.type != Token.Equals ?
                parse_type(ctx) :
                AstNode.inferred_type;

    auto value = ctx.skip_token(Token.Equals) ?
                 parse_expression(ctx) : 
                 AstNode.none;

    const span = lhs.span.merge(type.span);
    return new AstNode(AstNode.Variable, span, ctx.node_array(lhs, type, value));
}

AstNode parse_loop(ref ParseCtx ctx) {
    auto start_span = ctx.take_token().span;

    auto body = parse_statement(ctx);

    return new AstNode(AstNode.Loop, start_span.merge(body.span), body);
}

AstNode parse_if(ref ParseCtx ctx) {
    const start_span = ctx.take_token().span;

    auto condition = parse_expression(ctx);

    auto body = parse_statement(ctx);
    
    auto else_branch = ctx.skip_token(Token.Else) ?
                       parse_else(ctx) :
                       AstNode.none;
    
    const span = merge_all(start_span, body.span, else_branch.span);
    return new AstNode(AstNode.If, span, ctx.node_array(condition, body, else_branch));
}

alias parse_else = parse_statement;

AstNode parse_escape(AstNode.Type Type, Token.Type ttype, bool with_value)(ref ParseCtx ctx) {
    auto start_span = ctx.take_token().span;

    static if (with_value) {
        auto value = prefix_parselets[ctx.current.type] != prefix_parselets[Token.Invalid] ?
                     parse_expression(ctx) :
                     AstNode.none;

        const span = merge_all(start_span, value.span);
        return new AstNode(Type, span, value);
    }
    else
        return new AstNode(Type, start_span);
}

// ----------------------------------------------------------------------
//   ______                                    _                    
//  |  ____|                                  (_)                   
//  | |__   __  __ _ __   _ __  ___  ___  ___  _   ___   _ __   ___ 
//  |  __|  \ \/ /| '_ \ | '__|/ _ \/ __|/ __|| | / _ \ | '_ \ / __|
//  | |____  >  < | |_) || |  |  __/\__ \\__ \| || (_) || | | |\__ \
//  |______|/_/\_\| .__/ |_|   \___||___/|___/|_| \___/ |_| |_||___/
//                | |                                               
//                |_|                                               
// ----------------------------------------------------------------------

alias PrefixParseFn = AstNode function(ref ParseCtx ctx);
alias InfixParseFn = AstNode function(ref ParseCtx ctx, AstNode lhs);

struct Infix { Precedence precedence; InfixParseFn parselet; }

immutable prefix_parselets = () {
    PrefixParseFn[256] parselets = (ref ctx) {
        ctx.error(
            SyntaxError.TokenNotAnExpression,
            "The token \"%s\" cannot start an expression.",
            ctx.current.type
        );

        return new AstNode(AstNode.Invalid, ctx.current.span);
    };

    parselets[Token.Done]       = (ref ctx) {
        ctx.error(
            SyntaxError.UnexpectedEndOfFile,
            "Unexpected end of file while parsing source."
        );

        return new AstNode(AstNode.Invalid, ctx.current.span);
    };

    parselets[Token.Name]       = &parse_key_type!(AstNode.Name);
    parselets[Token.Integer]    = &parse_key_type!(AstNode.Integer);
    parselets[Token.Char]       = &parse_key_type!(AstNode.Char);
    parselets[Token.Minus]      = &parse_unary!(AstNode.Negate);
    parselets[Token.Bang]       = &parse_unary!(AstNode.Falsify);
    parselets[Token.Ampersand]  = &parse_unary!(AstNode.GetRef);
    parselets[Token.Star]       = &parse_unary!(AstNode.Pointer);
    parselets[Token.Lparen]     = &parse_seq!(AstNode.List, parse_list_member, Token.Rparen);
    parselets[Token.Lbracket]   = &parse_seq!(AstNode.List, parse_list_member, Token.Rbracket);
    parselets[Token.Lbrace]     = &parse_block;

    return parselets;
} ();

immutable infix_parselets = () {
    Infix[256] parselets;

    void set(AstNode.Type type, Token.Type ttype, Precedence prec, bool left_assoc = true, bool skip_op = true)() {
        parselets[ttype] = Infix(prec, &parse_binary!(type, left_assoc ? prec + 1 : prec, skip_op));
    }

    set!(AstNode.Assign,        Token.Equals,       Precedence.Assign   )();
    set!(AstNode.Less,          Token.Less,         Precedence.Compare  )();
    set!(AstNode.LessEqual,     Token.LessEqual,    Precedence.Compare  )();
    set!(AstNode.Greater,       Token.Greater,      Precedence.Compare  )();
    set!(AstNode.GreaterEqual,  Token.GreaterEqual, Precedence.Compare  )();
    set!(AstNode.Equal,         Token.EqualEqual,   Precedence.Equality )();
    set!(AstNode.NotEqual,      Token.BangEqual,    Precedence.Equality )();
    set!(AstNode.And,           Token.And,          Precedence.Logic    )();
    set!(AstNode.Or,            Token.Or,           Precedence.Logic    )();
    set!(AstNode.Add,           Token.Plus,         Precedence.Sum      )();
    set!(AstNode.Subtract,      Token.Minus,        Precedence.Sum      )();
    set!(AstNode.Multiply,      Token.Star,         Precedence.Product  )();
    set!(AstNode.Divide,        Token.Slash,        Precedence.Product  )();
    set!(AstNode.Power,         Token.Caret,        Precedence.Power,   false)();
    set!(AstNode.Call,          Token.Dot,          Precedence.Call     )();
    set!(AstNode.Call,          Token.Lparen,       Precedence.Call,    true, false)();
    set!(AstNode.Call,          Token.Lbracket,     Precedence.Call,    true, false)();
    parselets[Token.Colon]  = Infix(Precedence.Assign, &parse_var);
    parselets[Token.Rarrow] = Infix(Precedence.Primary, &parse_function);

    return parselets;
} ();

auto parse_key_type(AstNode.Type type)(ref ParseCtx ctx) {
    auto t = ctx.take_token();
    return new AstNode(type, t.span, t.key);
}

auto parse_unary(AstNode.Type type)(ref ParseCtx ctx) {
    auto op_span = ctx.take_token().span;
    auto operand = parse_expression(ctx);

    return new AstNode(type, op_span.merge(operand.span), operand);
}

AstNode parse_binary(AstNode.Type type, int precedence, bool skip_operator)(ref ParseCtx ctx, AstNode lhs) {
    static if (skip_operator)
        ctx.advance();
    
    auto rhs = parse_expression(ctx, cast(Precedence) precedence);

    if (lhs.type != AstNode.Invalid && rhs.type != AstNode.Invalid) {
        return new AstNode(type, lhs.span.merge(rhs.span), ctx.node_array(lhs, rhs));
    }
    else {
        scope(exit) ctx.free(lhs, rhs);
        return new AstNode(AstNode.Invalid, lhs.span.merge(rhs.span));
    }
}

AstNode parse_seq(AstNode.Type type, alias parse_member, Token.Type close_delim)(ref ParseCtx ctx) {
    ctx.delimiter_stack.insertBack(Token.Comma);
    const open_span = ctx.take_token().span;

    ctx.skip_token(Token.Comma);

    AstNode[] members;
    while (!ctx.current.type.matches_one(close_delim, Token.Done)) {
        members ~= parse_member(ctx);

        ctx.skip_token(Token.Comma);
    }

    ctx.delimiter_stack.removeBack();
    const close_token = ctx.take_token();

    if (close_token.type == close_delim) {
        return new AstNode(type, open_span.merge(close_token.span), members);
    }
    else {
        assert(close_token.type == Token.Done);
        
        ctx.free(members);
        
        bool has_eof_error;
        foreach (error; ctx.errors)
            if (error.code == SyntaxError.UnexpectedEndOfFile) {
                has_eof_error = true;
                break;
            }

        if (!has_eof_error)
            ctx.error(
                SyntaxError.UnexpectedEndOfFile,
                "Unexpected end of file while parsing source."
            );

        return new AstNode(AstNode.Invalid, open_span.merge(close_token.span));
    }
}

AstNode parse_list_member(ref ParseCtx ctx) {
    auto first = parse_expression(ctx, Precedence.Logic);

    const is_name = first.type == AstNode.Name;
    auto name = is_name && ctx.current.type.matches_one(Token.Equals, Token.Colon) ?
                first :
                AstNode.none;
    
    auto type = ctx.skip_token(Token.Colon) ?
                parse_type(ctx) :
                AstNode.inferred_type;
    
    auto expr = ctx.skip_token(Token.Equals) ?
                parse_expression(ctx) :
                name.type == AstNode.None ?
                    first :
                    AstNode.none;

    const span = name.span.merge(type.span).merge(expr.span);
    if (name.type != AstNode.Invalid && type.type != AstNode.Invalid && expr.type != AstNode.Invalid) {
        return new AstNode(AstNode.ListMember, span, ctx.node_array(name, type, expr));
    }
    else {
        ctx.free(name, type, expr);
        return new AstNode(AstNode.Invalid, span);
    }
}

AstNode parse_block(ref ParseCtx ctx) {
    ctx.delimiter_stack.insertBack(Token.Semicolon);
    const open_span = ctx.take_token().span;

    AstNode[] statements;
    while (!ctx.current.type.matches_one(Token.Done, Token.Rbrace)) {
        statements ~= parse_statement(ctx);
    }

    ctx.delimiter_stack.removeBack();
    const close_token = ctx.take_token();

    if (close_token.type == Token.Rbrace) {
        return new AstNode(AstNode.Block, open_span.merge(close_token.span), statements);
    }
    else {
        assert(close_token.type == Token.Done);

        ctx.error(
            SyntaxError.UnexpectedEndOfFile,
            "Unexpected end of file while parsing source."
        );

        // it's the end of the file, raise an error, but close the block so we can do further processing
        return new AstNode(AstNode.Block, open_span.merge(close_token.span), statements);
    }
}

AstNode parse_function(ref ParseCtx ctx, AstNode params) {
    assert(ctx.current.type == Token.Rarrow);
    ctx.advance();

    const saved_cursor = ctx.cursor.current;
    const saved_token = ctx.current;

    // Cleanup: We don't ignore any errors generated during this time...
    auto maybe_body = parse_expression(ctx);

    AstNode ret_type, fun_body;

    // the maybe_body is a type expression
    if (ctx.current.type == Token.Lbrace) {
        ctx.cursor.current = saved_cursor;
        ctx.current = saved_token;
        ctx.free(maybe_body);
        ret_type = parse_type(ctx);
        fun_body = parse_expression(ctx);
    }
    else {
        ret_type = AstNode.inferred_type;
        fun_body = maybe_body;
    }
    
    const span = merge_all(params.span, ret_type.span, fun_body.span);
    if (params.type != AstNode.Invalid && ret_type.type != AstNode.Invalid && fun_body.type != AstNode.Invalid)
        return new AstNode(AstNode.Function, span, ctx.node_array(params, ret_type, fun_body));
    else {
        ctx.free(params, ret_type, fun_body);
        return new AstNode(AstNode.Invalid, span);
    }
}

// ----------------------------------------------------------------------
//   _______                       
//  |__   __|                      
//     | | _   _  _ __    ___  ___ 
//     | || | | || '_ \  / _ \/ __|
//     | || |_| || |_) ||  __/\__ \
//     |_| \__, || .__/  \___||___/
//          __/ || |               
//         |___/ |_|               
// ----------------------------------------------------------------------

PrefixParseFn get_type_prefix_parselet(Token.Type t) {
    switch (t) {
        case Token.Name:
            return &parse_key_type!(AstNode.Name);

        case Token.Star:
            return &parse_unary!(AstNode.PointerType);

        case Token.Lparen:
            return &parse_seq!(AstNode.TypeList, parse_type_list_member, Token.Rparen);

        case Token.Lbracket:
            return &parse_seq!(AstNode.TypeList, parse_type_list_member, Token.Rbracket);

        default:
            return (ref ctx) {
                ctx.error(
                    SyntaxError.TokenNotAnExpression,
                    "The token \"%s\" cannot start an expression.",
                    ctx.current.type
                );
                return new AstNode(AstNode.Invalid, ctx.current.span);
            };
    }
}

Infix get_type_infix_parselet(Token.Type t) {
    switch (t) {
        case Token.Dot:
            return Infix(Precedence.Call, &parse_binary!(AstNode.Call, Precedence.Primary, true));

        case Token.Lparen:
            return Infix(Precedence.Call, &parse_binary!(AstNode.Call, Precedence.Primary, false));

        case Token.Lbracket:
            return Infix(Precedence.Call, &parse_binary!(AstNode.Call, Precedence.Primary, false));

        case Token.Rarrow:
            return Infix(Precedence.Primary, &parse_function_type);
        default:
            return Infix();
    }
}

AstNode parse_type_list_member(ref ParseCtx ctx) {
    auto first = parse_type(ctx);

    auto name = first.type == AstNode.Name && ctx.current.type == Token.Colon ?
                first :
                AstNode.none;
    
    auto type = ctx.skip_token(Token.Colon) ?
                parse_type(ctx) :
                first ;

    const span = name.span.merge(type.span);
    if (name.type != AstNode.Invalid && type.type != AstNode.Invalid) {
        return new AstNode(AstNode.TypeListMember, span, ctx.node_array(name, type));
    }
    else {
        ctx.free(name, type);
        return new AstNode(AstNode.Invalid, span);
    }
}

AstNode parse_function_type(ref ParseCtx ctx, AstNode lhs) {
    assert(lhs.type == AstNode.TypeList || lhs.type == AstNode.Invalid);
    assert(ctx.current.type == Token.Rarrow);
    ctx.advance();

    auto return_type = parse_type(ctx);
    const span = lhs.span.merge(return_type.span);

    if (lhs.type != AstNode.Invalid && return_type.type != AstNode.Invalid) {
        return new AstNode(AstNode.FunctionType, span, ctx.node_array(lhs, return_type));
    }
    else {
        ctx.free(lhs, return_type);
        return new AstNode(AstNode.Invalid, span);
    }
}

// ----------------------------------------------------------------------
//   _    _  _    _  _  _  _    _            
//  | |  | || |  (_)| |(_)| |  (_)           
//  | |  | || |_  _ | | _ | |_  _   ___  ___ 
//  | |  | || __|| || || || __|| | / _ \/ __|
//  | |__| || |_ | || || || |_ | ||  __/\__ \
//   \____/  \__||_||_||_| \__||_| \___||___/
// ----------------------------------------------------------------------

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

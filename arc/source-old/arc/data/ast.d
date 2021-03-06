/**
 This module contains the types that make up the abstract syntax tree, as well
 as the allocator used to allocate nodes and arrays of nodes.

 The primary goal of the allocation strategy for syntax nodes is to obtain a
 unique id for each node that is allocated during a compilation session. We
 assume that the compiler operates on a single compilation per execution (ie.
 not a continuous build server).

 The memory strategy for the syntax tree is thus as follows:
    * Assume that syntax errors will cause compilation to fail.
    * Assume that failed compilation artifacts will not be used after
      compilation.
    * Reserve a contiguous array of 2 ^ 32 AstNodeStorage objects.
    * Maintain a counter indicating last-used slot.
    * To allocate, increment counter and return indicated slot.
    * Deallocation of memory occurs only once, when the syntax tree is no longer
      needed (either because of error or after IR generation).
    * Reserve a second contiguous array of 2 ^ 32 `AstNodeId[]`s for array
      indices.
    * Reserve a third contiguous span of `AstNodeId.sizeof` * 2 ^ 32 managed by
      an array pool for arrays.
 */
module arc.data.ast;

import arc.data.hash;
import arc.data.scopes : ScopeId;
import arc.data.span;
import arc.data.symbol : SymbolId;
import arc.data.type;
import arc.indexed_allocator;

/**
 The AstNode contains the bare minimum of information necessary to make a
 decision about a node when traversing a syntax tree (its type, and the scope it
 belongs to).
 */
struct AstNode {
    import std.bitmanip : bitfields;

    enum Kind : ubyte {
        None,
        Invalid,
        InferredType,

        SymbolRef,
        Import,

        // Literals
        Integer,
        Char,
        String,

        // Unary Operators
        Not,
        Negate,
        Dereference,
        PointerType,

        // Binary Operators
        Assign,
        Add,
        Subtract,
        Multiply,
        Divide,
        Power,
        Less,
        LessEqual,
        Greater,
        GreaterEqual,
        Equal,
        NotEqual,
        And,
        Or,
        Call,
        Access,
        StaticAccess,

        // Functions
        Function,
        FunctionSignature,

        // Sequences
        List,
        Block,
        Loop,

        // Declarations
        ListMember,
        Definition,
        Variable,

        // Control Flow
        Break,
        Continue,
        Return,
        If,
    }

public:
    Kind kind;
    TypeId type_id;
    ScopeId outer_scope_id;
    Span location;

    this(Kind kind, ScopeId scope_id, Span location) {
        this.kind = kind;
        this.outer_scope_id = scope_id;
        this.location = location;
    }

    /// Checks if the node is of `AstNode.Kind.Invalid` kind. No further
    /// verification of node correctness is performed.
    bool is_valid() {
        return kind != Kind.Invalid;
    }
}

alias None = HeaderOnly!(AstNode.Kind.None);
alias InferredType = HeaderOnly!(AstNode.Kind.InferredType);
alias Invalid = HeaderOnly!(AstNode.Kind.Invalid);

alias Integer = Value!(AstNode.Kind.Integer, ulong);
alias String = Value!(AstNode.Kind.String, Hash);
alias Char = Value!(AstNode.Kind.Char, Hash);

struct Value(AstNode.Kind node_kind, T) {
    mixin ast_header;
    T value;

    this(ScopeId outer_scope_id, Span location, T value) {
        header = AstNode(node_kind, outer_scope_id, location);
        this.value = value;
    }
}

struct SymbolRef {
    mixin ast_header;
    SymbolId declaration;
    Hash name_hash;

    this(ScopeId outer_scope_id, Span location, Hash name_hash) {
        header = AstNode(AstNode.Kind.SymbolRef, outer_scope_id, location);
        this.name_hash = name_hash;
    }
}

struct Import {
    mixin ast_header;
    mixin arity!(AstNode.Kind.Import, "call_path");
    ScopeId imported_file;
}

struct UnOp {
    mixin ast_header;
    mixin arity!(AstNode.Kind.InferredType, "operand");
    SymbolId op_symbol_id;
}

struct BinOp {
    mixin ast_header;
    mixin arity!(AstNode.Kind.InferredType, "lhs", "rhs");
    SymbolId op_symbol_id;
}

struct Function {
    mixin ast_header;
    mixin arity!(AstNode.Kind.Function, "parameters", "result", "body");
}

struct FunctionSignature {
    mixin ast_header;
    mixin arity!(AstNode.Kind.FunctionSignature, "parameters", "result");
}

alias List = Sequence!(AstNode.Kind.List);
alias Block = Sequence!(AstNode.Kind.Block);
alias Loop = Sequence!(AstNode.Kind.Loop);

struct Sequence(AstNode.Kind node_kind) {
    mixin ast_header;
    ScopeId seq_scope_id;
    AstNodeId[] members;

    this(ScopeId outer_scope_id, Span location, ScopeId new_scope_id, AstNodeId[] members) {
        header = AstNode(node_kind, outer_scope_id, location);
        seq_scope_id = new_scope_id;
        this.members = members;
    }
}

alias ListMember = Declaration!(AstNode.Kind.ListMember);
alias Definition = Declaration!(AstNode.Kind.Definition);
alias Variable = Declaration!(AstNode.Kind.Variable);

struct Declaration(AstNode.Kind node_kind) {
    mixin ast_header;
    mixin arity!(AstNode.Kind.None, "type_expr", "init_expr");
    SymbolId symbol;

    this(ScopeId outer_scope_id, Span location, SymbolId symbol, AstNodeId type_expr_id, AstNodeId init_expr_id) {
        header = AstNode(node_kind, outer_scope_id, location);
        parts = [type_expr_id, init_expr_id];
        this.symbol = symbol;
    }
}

alias Break = HeaderOnly!(AstNode.Kind.Break);
alias Continue = HeaderOnly!(AstNode.Kind.Continue);

struct HeaderOnly(AstNode.Kind node_kind) {
    mixin ast_header;

    this(ScopeId outer_scope_id, Span location) {
        header = AstNode(node_kind, outer_scope_id, location);
    }
}

struct Return {
    mixin ast_header;
    mixin arity!(AstNode.Kind.Return, "value");
}

struct If {
    mixin ast_header;
    mixin arity!(AstNode.Kind.If, "condition", "pass_branch", "fail_branch");
}

/**
 A `SyntaxTree` object represents a single source-file's abstract syntax tree.
 */
struct SyntaxTree {
    import arc.source : Source;

public:
    this(AstAllocator allocator, Source* source, AstNodeId[] statements) {
        _nodes = allocator;
        _statements = statements;
        _source = source;
    }

    Source* source() { return _source; }

    AstNodeId none() {
        return _nodes.none;
    }

    /// Retrieves the list of statements contained within the parsed syntax
    /// tree.
    AstNodeId[] statements() {
        return _statements;
    }

    AstNode* opIndex(AstNodeId id) {
        return _nodes[id];
    }

    AstNodeId[] children_of(AstNodeId id) {
        return _nodes.children_of(id);
    }

    ReturnType match(ReturnType, Ops...)(AstNodeId id, Ops ops) if (Ops.length > 0) {
        return _nodes.match!ReturnType(id, ops);
    }

private:
    AstAllocator _nodes;
    AstNodeId[] _statements;
    Source* _source;
}

alias AstNodeId = AllocIndex!(uint, AstNode*);

final class AstAllocator : SimpleIndexedAllocator!(uint, AstNode*) {
    const AstNodeId none;

    this() {
        super();
        none = save(None(ScopeId(), Span()));
    }

    alias save = SimpleIndexedAllocator!(uint, AstNode*).save;

    AstNodeId save(Node)(Node node) {
        auto n = new Node();
        *n = node;
        return save(cast(AstNode*) n);
    }

    /// Convenience function to retrieve any children that a node may have as an
    /// `AstNodeId[]`. Any node without children will return an empty array.
    AstNodeId[] children_of(AstNodeId id) {
        // dfmt off
        return match!(AstNodeId[])(id,
            (UnOp* op)              => op.parts[],
            (BinOp* op)             => op.parts[],
            (Import* im)            => im.parts[],
            (Function* fn)          => fn.parts[],
            (FunctionSignature* fs) => fs.parts[],
            (List* ls)              => ls.members[],
            (Block* bk)             => bk.members[],
            (Loop* lp)              => lp.members[],
            (ListMember* lm)        => lm.parts[],
            (Definition* df)        => df.parts[],
            (Variable* vr)          => vr.parts[],
            (Return* rt)            => rt.parts[],
            (If* i)                 => i.parts[],
            (AstNode* n)            => cast(AstNodeId[])[]);
        // dfmt on
    }

    /**
     Convenience function to switch on the type of an `AstNode`.

     Params:
        id  = The id of the node to be switched upon.
        ops = A variadic list of functions or delegates taking the a pointer to
              the node type as a parameter. If a catch-all clause is desired,
              the last branch may be accept an `AstNode*` as a parameter.
     */
    ReturnType match(ReturnType, Ops...)(AstNodeId id, Ops ops) if (Ops.length > 0) {
        import std.traits : Parameters;
        import std.meta : staticIndexOf, staticMap, AliasSeq;

        static dispatch(T)(AstNode* n, Ops ops) {
            enum int i = staticIndexOf!(T*, staticMap!(Parameters, Ops));
            static if (i >= 0)
                return ops[i](cast(T*) n);
            else static if (is(Parameters!(ops[$ - 1]) == AliasSeq!(AstNode*)))
                return ops[$ - 1](n);
            else static if (!is(ReturnType == void))
                return ReturnType.init;
            else
                return;
        }

        auto node = this[id];
        // dfmt off
        switch (node.kind) {
            case AstNode.Kind.Invalid:            return dispatch!Invalid(node, ops);
            case AstNode.Kind.None:               return dispatch!None(node, ops);
            case AstNode.Kind.InferredType:       return dispatch!InferredType(node, ops);
            case AstNode.Kind.SymbolRef:          return dispatch!SymbolRef(node, ops);
            case AstNode.Kind.Import:             return dispatch!Import(node, ops);
            case AstNode.Kind.Char:               return dispatch!Char(node, ops);
            case AstNode.Kind.String:             return dispatch!String(node, ops);
            case AstNode.Kind.Integer:            return dispatch!Integer(node, ops);
            case AstNode.Kind.Not: .. case AstNode.Kind.PointerType:
                                                        return dispatch!UnOp(node, ops);
            case AstNode.Kind.Assign: .. case AstNode.Kind.StaticAccess:
                                                        return dispatch!BinOp(node, ops);
            case AstNode.Kind.Function:           return dispatch!Function(node, ops);
            case AstNode.Kind.FunctionSignature:  return dispatch!FunctionSignature(node, ops);
            case AstNode.Kind.ListMember:         return dispatch!ListMember(node, ops);
            case AstNode.Kind.Definition:         return dispatch!Definition(node, ops);
            case AstNode.Kind.Variable:           return dispatch!Variable(node, ops);
            case AstNode.Kind.List:               return dispatch!List(node, ops);
            case AstNode.Kind.Block:              return dispatch!Block(node, ops);
            case AstNode.Kind.Loop:               return dispatch!Loop(node, ops);
            case AstNode.Kind.Break:              return dispatch!Break(node, ops);
            case AstNode.Kind.Continue:           return dispatch!Continue(node, ops);
            case AstNode.Kind.Return:             return dispatch!Return(node, ops);
            case AstNode.Kind.If:                 return dispatch!If(node, ops);
            default: assert(false);
        }
        // dfmt on
    }
}

private:

mixin template ast_header() {
    AstNode header;
    alias header this;
}

/**
 Mixin template for creating nodes with specific children. Each child is given a
 name by which it is referred, though all children may be collectively referred
 to by `parts`.

 `arity` will automatically create a constructor if `node_kind` is not
 `AstNode.Kind.None`, and will take the kind of ast node as an argument if
 `node_kind` is `AstNode.Kind.InferredType`.

 For example:  
    ```
    arity!(AstNode.Kind.None, ...) -> no constructor  

    arity!(AstNode.Kind.InferredType, ...) -> this(AstNode.Kind, ScopeId, ...)  

    arity!(_anything_else_, ...) -> this(ScopeId, ...)  
    ```
 */
mixin template arity(AstNode.Kind node_kind, Names...) {
    import std.algorithm : map;
    import std.format : format;

    union {
        AstNodeId[Names.length] parts;
        struct {
            static foreach (name; Names)
                mixin("AstNodeId " ~ name ~ ";");
        }
    }

    static if (node_kind)
        mixin((string[] names...) {
            auto params = names.map!(s => "AstNodeId " ~ s ~ ", ");
            auto array_parts = names.map!(s => s ~ ", ");

            if (node_kind == AstNode.Kind.InferredType)
                return "this(AstNode.Kind kind, ScopeId outer_scope_id, Span location, %-(%s%)) {
                    header = AstNode(kind, outer_scope_id, location);
                    parts = [%-(%s%)];
                }".format(params, array_parts);
            else
                return "this(ScopeId outer_scope_id, Span location, %-(%s%)) {
                    header = AstNode(AstNode.Kind.%s, outer_scope_id, location);
                    parts = [%-(%s%)];
                }".format(params, node_kind, array_parts);
        }(Names));
}

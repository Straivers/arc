module arc.data.hash;

struct Hash {
    ulong value;
}

/**
 * Hashes text and returns (key: ubyte[8], text: const(char)[])
 */
Hash hash_of(T: const(char)[])(T text) pure {
    import std.digest.murmurhash : hash = digest, MurmurHash3;

    auto key = hash!(MurmurHash3!(128))(text);

    return (cast(Hash*) key.ptr)[0];
}

Hash hash_of(T)(auto ref T t) {
    import std.digest.murmurhash : hash = digest, MurmurHash3;

    static if (__traits(compiles, t.toHash()))
        return t.toHash();
    
    auto key = hash!(MurmurHash3!128)((&t)[0 .. 1]);
    return (cast(Hash*) key.ptr)[0];
}

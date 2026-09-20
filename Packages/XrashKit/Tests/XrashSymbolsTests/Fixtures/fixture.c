// Three nested functions, each on a line this file will not move, so a symbol
// lookup and a line lookup both have something stable to land on.
//
// Built by build.sh into fixture.dylib and fixture.dylib.dSYM. `stripped` sits
// between two named functions and is `static`, so `strip -x` takes its name out
// of the dylib while LC_FUNCTION_STARTS still records where it begins: a frame
// inside it must come back nameless rather than wearing gamma's name.

__attribute__((noinline)) int gamma(int x) {
    return x * 3; // line 10
}

static __attribute__((noinline)) int stripped(int x) {
    return x - 1; // line 14
}

__attribute__((noinline)) int beta(int x) {
    return gamma(stripped(x)) + 2; // line 18
}

__attribute__((noinline)) int alpha(int x) {
    return beta(x) + 1; // line 22
}

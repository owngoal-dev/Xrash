#!/bin/sh
# Rebuilds the symbolication fixture: a tiny dylib with DWARF beside it.
#
# The products (fixture.dylib, fixture.dylib.dSYM) are committed, because the
# tests need the same bytes on every machine and a dSYM of three functions is
# a few kilobytes. Run this only when the source below changes — the UUID and
# the line numbers are written into MachOSliceTests, so a rebuild means
# updating `FixtureBinary` there with what `dwarfdump --uuid` now prints.
#
# macOS arm64 rather than iphoneos: the harness runs on the Mac, and the DWARF
# a dSYM carries is the same either way.
set -eu
cd "$(dirname "$0")"

# Two steps on purpose: dsymutil reads the DWARF out of the object file, and
# a one-shot `clang -dynamiclib` deletes that object before it can.
# -fdebug-compilation-dir keeps whoever's checkout built this out of the
# committed DWARF: the line table names `fixture.c` under `.`, not under a
# path from someone's home directory.
xcrun clang -arch arm64 -g -O0 -fdebug-compilation-dir=. -c -o fixture.o fixture.c
xcrun clang -arch arm64 -dynamiclib -o fixture.dylib fixture.o
xcrun dsymutil fixture.dylib
rm fixture.o
xcrun strip -x fixture.dylib

xcrun dwarfdump --uuid fixture.dylib

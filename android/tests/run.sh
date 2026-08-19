#!/bin/bash
# Plain javac/java, no test framework, for the same reason the SDK's own suites use a bare
# node runner: these classes are pure Java with no Android imports, so a JUnit/Robolectric
# dependency would buy nothing and cost a toolchain.
#
#   ./android/tests/run.sh
#
# OUTSIDE src/ on purpose — anything under src/main is compiled into the shipped AAR.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src/main/java"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

mkdir -p "$OUT/com/oney/WebRTCModule/audio"
cp "$SRC"/com/oney/WebRTCModule/audio/*.java "$OUT/com/oney/WebRTCModule/audio/"
cp "$HERE"/BusTest.java "$OUT/"

cd "$OUT"
javac -nowarn com/oney/WebRTCModule/audio/*.java BusTest.java
java BusTest

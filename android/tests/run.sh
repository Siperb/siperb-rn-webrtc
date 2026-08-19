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

# NAMED, not globbed. The audio package also holds ConferenceMixManager, which is the
# WebRTC/Android wiring and cannot compile off-device -- globbing dragged it in and turned a
# green suite into 40 unrelated errors. These four are the pure-Java core and the only part
# a JVM can meaningfully test.
PURE="ConferenceAudioBus AudioSource ShortRingBuffer LinearResampler"

mkdir -p "$OUT/com/oney/WebRTCModule/audio"
for f in $PURE; do
    cp "$SRC/com/oney/WebRTCModule/audio/$f.java" "$OUT/com/oney/WebRTCModule/audio/"
done
cp "$HERE"/BusTest.java "$OUT/"

cd "$OUT"
javac -nowarn com/oney/WebRTCModule/audio/*.java BusTest.java
java BusTest

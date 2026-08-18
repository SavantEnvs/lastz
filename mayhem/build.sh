#!/usr/bin/env bash
#
# mayhem/build.sh — build the LASTZ fuzz target + the project's own test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) exports the build contract — CC/CXX, SANITIZER_FLAGS (ASan+UBSan,
# halting), DEBUG_FLAGS (DWARF<4), LIB_FUZZING_ENGINE, SRC=/mayhem.
#
# TWO independent builds:
#   1) FUZZ target — LASTZ built with $SANITIZER_FLAGS + $DEBUG_FLAGS so the fuzzed code itself is
#      instrumented and carries DWARF<4. The stock `lastz` CLI is a natural-crash file-input driver,
#      so the sanitized binary doubles as the standalone reproducer (no libFuzzer runtime to strip).
#      Installed at /mayhem/mayhem/lastz/lastz (the Mayhemfile cmd).
#   2) TEST suite — LASTZ (lastz + lastz_D) built with NORMAL flags (no sanitizer) left in src/ so
#      mayhem/test.sh only RUNS the upstream `make test`/`make base_tests` recipes, never compiles.
#
# Additive: the upstream Makefiles are NOT edited. LASTZ's src/Makefile hardcodes `CC=gcc`, bakes
# `-Werror` into CFLAGS, and offers no post-CFLAGS hook — so we drive it through a small CC wrapper
# (generated here, under /tmp) that APPENDS our flags (and -Wno-error) AFTER the Makefile's flags,
# guaranteeing they win without touching a tracked file.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# FUZZ compiler: AFL's clang so the target carries AFL edge instrumentation (Mayhemfile `afl: true`).
# LASTZ's `lastz` is a black-box file-input CLI; Mayhem's binary-only tracer records 0 edges on this
# ASan binary (dynamic_analysis fails), so — per SPEC.md §"instrumented harness" and TODO.md's AFL
# fix for 0-edge CLI targets — we compile it with afl-clang-fast (AFL_* coverage) instead of relying
# on binary-only tracing. afl-clang-fast forwards $SANITIZER_FLAGS to clang, so ASan+UBSan stay on.
: "${FUZZ_CC:=afl-clang-fast}"
export AFL_QUIET=1
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
# Narrow UBSan relax for the FUZZ build only (ASan + the rest of halting UBSan stay ON): LASTZ's
# binary-format reader read_4_little() (src/sequences.c:9228) builds a u32 as `seq_getc()<<24`, and
# any input byte >=128 makes that promoted-int left shift overflow — benign (the value is stored in
# a u32), but with halting UBSan it aborts on ~every malformed/binary-magic input. That flood makes
# the fork/exec target "crash on everything" so Mayhem never establishes coverage (0 edges, "Run
# Failed"). Relax ONLY the `shift` check, exactly as PORTING.md prescribes (cf. swftools). Applied
# after $SANITIZER_FLAGS so the -fno-sanitize wins; empty SANITIZER_FLAGS (off-switch) => empty relax.
FUZZ_SAN_RELAX=""
[ -n "$SANITIZER_FLAGS" ] && FUZZ_SAN_RELAX="-fno-sanitize=shift"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS FUZZ_SAN_RELAX

cd "$SRC"

# --- __asan_default_options object: baked into the fuzz binary on its LINK step -------------------
# LASTZ's Makefile hard-codes its source list, so we can't add a .c to it; instead we compile the
# hook object here and force-inject it into the final link (the link recipe is `CC LDFLAGS objs -lm
# -o lastz`, no -c). This bakes detect_leaks=0 without touching a tracked Makefile/source.
ASAN_OPTS_OBJ=""
if [ -n "$SANITIZER_FLAGS" ]; then
  ASAN_OPTS_OBJ=/tmp/lastz-asan-opts.o
  "$CC" $SANITIZER_FLAGS -c "$SRC/mayhem/asan_default_options.c" -o "$ASAN_OPTS_OBJ"
fi

# --- CC wrappers: append flags AFTER the Makefile's (so -Wno-error beats the baked -Werror) --------
# The fuzz wrapper injects $ASAN_OPTS_OBJ on LINK steps only (compile steps carry -c) so
# __asan_default_options() is linked into src/lastz.
SAN_CC=/tmp/lastz-cc-san.sh
cat > "$SAN_CC" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-c" ] && exec "$FUZZ_CC" "\$@" $SANITIZER_FLAGS $FUZZ_SAN_RELAX $DEBUG_FLAGS -Wno-error; done
exec "$FUZZ_CC" "\$@" ${ASAN_OPTS_OBJ:-} $SANITIZER_FLAGS $FUZZ_SAN_RELAX $DEBUG_FLAGS -Wno-error
EOF
NORM_CC=/tmp/lastz-cc-norm.sh
cat > "$NORM_CC" <<EOF
#!/usr/bin/env bash
exec "$CC" "\$@" $COVERAGE_FLAGS -Wno-error
EOF
chmod +x "$SAN_CC" "$NORM_CC"

# --- 1) FUZZ build: sanitized + DWARF; install as the Mayhemfile target ---------------------------
make -C "$SRC/src" clean >/dev/null 2>&1 || true
make -C "$SRC/src" CC="$SAN_CC" -j"$MAYHEM_JOBS" lastz
mkdir -p "$SRC/mayhem/lastz"
cp "$SRC/src/lastz" "$SRC/mayhem/lastz/lastz"

# --- 2) TEST build: normal flags, left in src/ for mayhem/test.sh to RUN ---------------------------
make -C "$SRC/src" clean >/dev/null 2>&1 || true
make -C "$SRC/src" CC="$NORM_CC" -j"$MAYHEM_JOBS" lastz lastz_D

echo "build.sh: fuzz target at $SRC/mayhem/lastz/lastz; test binaries at $SRC/src/{lastz,lastz_D}"

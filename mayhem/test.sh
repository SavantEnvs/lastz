#!/usr/bin/env bash
#
# mayhem/test.sh — RUN LASTZ's OWN upstream functional test suite (already built by mayhem/build.sh).
#
# This runs the project's real behavioral tests: the `test` target plus every sub-test of the
# upstream `base_tests` target (src/Makefile). Each runs the prebuilt ./lastz (or ./lastz_D) on
# fixture inputs and asserts the output byte-for-byte against a golden file via diff /
# tools/{lav,gfa,axt}_compare.py — so neutering LASTZ to exit(0) yields empty/wrong output and FAILS.
# We do NOT compile here (build.sh already produced src/{lastz,lastz_D} with normal flags; the recipes
# see them up-to-date and only run). Emits a CTRF summary and exits nonzero iff any test failed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# The upstream `base_tests` target's sub-tests (src/Makefile) + the `test` target.
TESTS=(
  test
  base_test_hits base_test_hsp base_test_adaptive_k base_test_default base_test_axt
  base_test_chained base_test_extended base_test_interpolated base_test_segments
  base_test_stdin2 base_test_2bit1 base_test_2bit2 base_test_float base_test_seeded
  base_test_hw_seeded base_test_ow_seeded base_test_masking base_test_anchors
  base_test_anchors_multi base_test_subrange base_test_mask base_test_coi
  base_test_multi base_test_multi_subrange
)

passed=0; failed=0
for t in "${TESTS[@]}"; do
  # -o lastz -o lastz_D: treat the prebuilt binaries as up-to-date so a recipe with a `lastz`
  # prerequisite (e.g. `test`) never triggers a compile here.
  if make -C "$SRC/src" -o lastz -o lastz_D "$t" >/tmp/lastz-test.$t.log 2>&1; then
    echo "PASS $t"; passed=$((passed+1))
  else
    echo "FAIL $t"; sed 's/^/    /' "/tmp/lastz-test.$t.log" | tail -8; failed=$((failed+1))
  fi
done

emit_ctrf "lastz-make-base_tests" "$passed" "$failed" 0

/*
 * Baked ASan runtime options for the LASTZ fuzz target.
 *
 * LASTZ is an allocate-and-exit batch aligner: on empty-sequence / malformed-input warning paths it
 * exits WITHOUT freeing its allocations, so LeakSanitizer (on by default inside ASan) aborts on ~18%
 * of the corpus (measured 755/4286). That flood makes Mayhem's behavior-testing "fail to run to
 * completion" and starves the fuzzer of coverage (0 edges). detect_leaks=0 is the sanctioned relax
 * for allocate-and-exit batch tools (HARNESS POLICY). We bake it via __asan_default_options() — the
 * runtime hook Mayhem endorses — rather than ASAN_OPTIONS (which Mayhem owns at run time). ASan's
 * heap/stack/global overflow + use-after-free detection all stay ON, so the real out-of-bounds reads
 * still surface as defects.
 */
const char *__asan_default_options(void);
const char *__asan_default_options(void) { return "detect_leaks=0"; }

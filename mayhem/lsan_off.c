// Build-time LSan disable: LASTZ is an allocate-and-exit batch tool that floods LeakSanitizer on
// malformed input; ASan stays on. Mayhem alone owns ASAN_OPTIONS/LSAN_OPTIONS at run time.
int __lsan_is_turned_off(void) { return 1; }

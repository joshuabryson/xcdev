#include <stdlib.h>

// Runs as the test bundle loads, before any test (or any thread of the tests) starts, so every git the tests run,
// and every git that xcd runs for them, reads no global or system config: the person's own settings, hooks above
// all (Git LFS's run on every commit and checkout), neither slow the tests nor run in them. Each throwaway repo's
// own config, and what a command passes with -c, still apply.
__attribute__((constructor))
static void isolateGit(void) {
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1);
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1);
}

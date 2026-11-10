#include "moo_crash_writer.h"
#include <signal.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3 || moo_crash_install(argv[1]) != 0) { return 90; }
    if (strcmp(argv[2], "disabled") == 0) { moo_crash_set_enabled(0); }
    if (strcmp(argv[2], "reset") == 0) { moo_crash_reset(argv[1]); }
    if (strcmp(argv[2], "segv") == 0) {
        *(volatile int *)0 = 1;
    } else if (strcmp(argv[2], "trap") == 0) {
        __builtin_trap();
    } else {
        raise(SIGABRT);
    }
    return 91; /* 任何致命信号后返回宿主都算失败。 */
}

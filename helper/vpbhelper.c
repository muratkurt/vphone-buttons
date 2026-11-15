// vpbhelper: VPhone Buttons' helper in the guest, run as a one-shot launchd job.
//   vpbhelper join <out> <part>...  writes the parts to <out> in order and deletes them
//                                    (the control socket cannot append to a file, so packages go up in parts)
//   vpbhelper kill <name>            sends SIGTERM to every process with that name
//                                    (cfprefsd, so an app reads preferences written behind its back)
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/param.h>

// libproc is in libSystem on iOS, but the SDK has no header for it.
int proc_listallpids(void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);

static int join(int argc, char **argv) {
    FILE *o = fopen(argv[0], "wb");
    if (!o) return 3;
    static char buf[1 << 16];
    for (int i = 1; i < argc; i++) {
        FILE *p = fopen(argv[i], "rb");
        if (!p) return 4;
        size_t n;
        while ((n = fread(buf, 1, sizeof buf, p)) > 0)
            if (fwrite(buf, 1, n, o) != n) return 5;
        fclose(p);
        unlink(argv[i]);
    }
    return fclose(o) == 0 ? 0 : 6;
}

static int killall(const char *name) {
    static pid_t pids[8192];
    int n = proc_listallpids(pids, sizeof pids);
    for (int i = 0; i < n; i++) {
        char found[2 * MAXCOMLEN + 1] = {0};
        if (pids[i] > 1 && proc_name(pids[i], found, sizeof found) > 0 && strcmp(found, name) == 0) kill(pids[i], SIGTERM);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 4 && strcmp(argv[1], "join") == 0) return join(argc - 2, argv + 2);
    if (argc == 3 && strcmp(argv[1], "kill") == 0) return killall(argv[2]);
    return 2;
}

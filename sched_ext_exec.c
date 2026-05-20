#define _GNU_SOURCE
#include <errno.h>
#include <linux/sched.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef SCHED_EXT
#define SCHED_EXT 7
#endif

static void usage(const char *prog)
{
    fprintf(stderr, "Usage: %s <command> [args...]\n", prog);
}

int main(int argc, char **argv)
{
    struct sched_param param = {0};

    if (argc < 2) {
        usage(argv[0]);
        return 2;
    }

    if (sched_setscheduler(0, SCHED_EXT, &param) != 0) {
        fprintf(stderr, "%s: sched_setscheduler(SCHED_EXT) failed: %s\n",
                argv[0], strerror(errno));
        return 1;
    }

    execvp(argv[1], &argv[1]);
    fprintf(stderr, "%s: execvp(%s) failed: %s\n", argv[0], argv[1], strerror(errno));
    return 127;
}

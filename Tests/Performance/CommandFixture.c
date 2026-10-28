#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void writeAll(int fd, const void *data, size_t count) {
    const char *bytes = data;
    while (count) {
        ssize_t written = write(fd, bytes, count);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) _exit(4);
        bytes += written;
        count -= written;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (!strcmp(argv[1], "echo")) {
        if (argc > 2) writeAll(1, argv[2], strlen(argv[2]));
    } else if (!strcmp(argv[1], "flood")) {
        char block[4096];
        memset(block, 'x', sizeof(block));
        for (int i = 0; i < 64; i++) writeAll(2, block, sizeof(block));
        for (int i = 0; i < 64; i++) writeAll(1, block, sizeof(block));
    } else if (!strcmp(argv[1], "ignore-term")) {
        signal(SIGTERM, SIG_IGN);
        sleep(30);
    } else if (!strcmp(argv[1], "closed-output")) {
        signal(SIGTERM, SIG_IGN);
        close(1);
        close(2);
        sleep(30);
    } else if (!strcmp(argv[1], "descendant")) {
        pid_t child = fork();
        if (child < 0) return 3;
        if (!child) { signal(SIGTERM, SIG_IGN); sleep(30); _exit(0); }
        if (argc > 2) {
            FILE *file = fopen(argv[2], "w");
            if (!file) return 4;
            fprintf(file, "%d", child);
            fclose(file);
        }
    } else if (!strcmp(argv[1], "exit")) {
        writeAll(1, "out", 3);
        writeAll(2, "err", 3);
        return 42;
    } else if (!strcmp(argv[1], "stdin")) {
        char value;
        if (read(0, &value, 1) != 0) return 5;
        writeAll(1, "closed", 6);
    } else if (!strcmp(argv[1], "descriptor")) {
        if (argc < 3) return 2;
        return fcntl(atoi(argv[2]), F_GETFD) == -1 && errno == EBADF ? 0 : 6;
    } else {
        return 2;
    }
    return 0;
}

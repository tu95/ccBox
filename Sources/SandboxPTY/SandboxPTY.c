#include "SandboxPTY.h"
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

pid_t sandbox_pty_spawn(const char *path, char *const argv[], char *const environment[],
                        const char *directory, uint16_t columns, uint16_t rows, int *master) {
    int descriptor_limit = getdtablesize();
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    pid_t child = forkpty(master, NULL, NULL, &size);
    if (child == 0) {
        // Avoid allocation and application code between fork and exec.
        if (chdir(directory) != 0) {
            const char error[] = "Could not enter the selected workspace.\r\n";
            write(STDERR_FILENO, error, sizeof(error) - 1);
            _exit(126);
        }
        for (int fd = STDERR_FILENO + 1; fd < descriptor_limit; fd++) {
            close(fd);
        }
        execve(path, argv, environment);
        const char error[] = "Could not start the sandbox runtime.\r\n";
        write(STDERR_FILENO, error, sizeof(error) - 1);
        _exit(127);
    }
    return child;
}

int32_t sandbox_pty_wait(pid_t child) {
    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            return 255;
        }
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 255;
}

void sandbox_pty_resize(int master, uint16_t columns, uint16_t rows) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    ioctl(master, TIOCSWINSZ, &size);
}

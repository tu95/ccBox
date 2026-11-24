#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *debugInput = getenv("CCBOX_CDP_READ_FD");
    const char *debugOutput = getenv("CCBOX_CDP_WRITE_FD");
    if (debugInput && debugOutput && argc > 1) {
        if (dup2(0, 3) < 0 || dup2(1, 4) < 0) return 115;
        execv(argv[1], &argv[1]);
        return 116;
    }

    uint32_t size = 0;
    if (_NSGetExecutablePath(NULL, &size) != -1) return 110;
    char *executable = malloc(size + 1);
    char *configuration = malloc(size + 32);
    char **arguments = calloc((size_t)argc + 3, sizeof(char *));
    if (!executable || !configuration || !arguments) return 111;
    if (_NSGetExecutablePath(executable, &size) != 0) return 112;
    strcpy(configuration, executable);
    strcat(configuration, ".ccbox-launch");

    arguments[0] = "/bin/sh";
    arguments[1] = configuration;
    arguments[2] = executable;
    for (int index = 1; index < argc; index++) {
        arguments[index + 2] = argv[index];
    }
    arguments[argc + 2] = NULL;
    execv(arguments[0], arguments);
    perror("ccbox nested launcher");
    return 113;
}

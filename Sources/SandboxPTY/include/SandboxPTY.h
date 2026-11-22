#ifndef SANDBOX_PTY_H
#define SANDBOX_PTY_H

#include <stdint.h>
#include <sys/types.h>

// Returns the child PID on success, with the master descriptor in master.
pid_t sandbox_pty_spawn(const char *path, char *const argv[], char *const environment[],
                        const char *directory, uint16_t columns, uint16_t rows, int *master);
int32_t sandbox_pty_wait(pid_t child);
void sandbox_pty_resize(int master, uint16_t columns, uint16_t rows);

#endif

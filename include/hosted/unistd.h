#ifndef _UNISTD_H
#define _UNISTD_H

#include <stddef.h>
#include <sys/types.h>

#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

ssize_t read(int fd, void *buf, size_t n);
ssize_t write(int fd, const void *buf, size_t n);
int close(int fd);
off_t lseek(int fd, off_t off, int whence);
int unlink(const char *path);
int rmdir(const char *path);
int isatty(int fd);
int dup(int fd);
int dup2(int a, int b);
int pipe(int fd[2]);
pid_t fork(void);
pid_t getpid(void);
int execv(const char *path, char *const argv[]);
int execvp(const char *file, char *const argv[]);
unsigned int sleep(unsigned int n);
int chdir(const char *path);
char *getcwd(char *buf, size_t n);
int access(const char *path, int mode);
void _exit(int code);

#endif

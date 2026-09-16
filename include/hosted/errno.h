#ifndef _ERRNO_H
#define _ERRNO_H

/* errno is per thread, so it is a function call */
int *__errno_location(void);
#define errno (*__errno_location())

#define EDOM	33
#define EILSEQ	84
#define ERANGE	34
#define EINTR	4
#define ENOMEM	12
#define ENOENT	2

#endif

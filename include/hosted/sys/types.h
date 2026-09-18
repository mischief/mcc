#ifndef _SYS_TYPES_H
#define _SYS_TYPES_H

#include <stddef.h>

/* The glibc spellings on a 64-bit machine, because these headers exist to
 * agree with the library a program is linked against. */
typedef long           ssize_t;
typedef long           off_t;
typedef unsigned long  ino_t;
typedef unsigned long  dev_t;
typedef unsigned int   mode_t;
typedef unsigned long  nlink_t;
typedef unsigned int   uid_t;
typedef unsigned int   gid_t;
typedef int            pid_t;
typedef long           time_t;
typedef long           suseconds_t;
typedef long           blksize_t;
typedef long           blkcnt_t;
typedef unsigned int   useconds_t;
typedef long           clock_t;
typedef unsigned char  u_char;
typedef unsigned short u_short;
typedef unsigned int   u_int;
typedef unsigned long  u_long;

#endif

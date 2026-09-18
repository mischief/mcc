#ifndef _DLFCN_H
#define _DLFCN_H

#define RTLD_LAZY	0x00001
#define RTLD_NOW	0x00002
#define RTLD_NOLOAD	0x00004
#define RTLD_DEEPBIND	0x00008
#define RTLD_GLOBAL	0x00100
#define RTLD_LOCAL	0
#define RTLD_NODELETE	0x01000

void *dlopen(const char *file, int mode);
int dlclose(void *handle);
void *dlsym(void *handle, const char *name);
char *dlerror(void);

#endif

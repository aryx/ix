// The part of goken's libc the tests use, declared for TinyC and 7c
// alike (Plan 9's C: long is 4 bytes, vlong is long long).
typedef unsigned char uchar;
typedef unsigned long ulong;
typedef long long vlong;
typedef unsigned long long uvlong;

extern int print(char*, ...);
extern int sprint(char*, char*, ...);
extern void exits(char*);
extern void *malloc(ulong);
extern void free(void*);
extern long strlen(char*);
extern char *strcpy(char*, char*);
extern int strcmp(char*, char*);
extern void *memset(void*, int, ulong);
extern int atoi(char*);

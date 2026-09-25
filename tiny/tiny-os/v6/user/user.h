// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// What a program of tiny-os v6 has: its system calls (usys.tm, and
// start.tm's write and exits) and libc (../../libc/: print, the strings,
// malloc), as xv6's user.h.

typedef unsigned int uint;
typedef unsigned long ulong;

struct stat { int type; int ino; uint size; };
struct dirent { int inum; char name[12]; };

#define T_DIR 1
#define T_FILE 2
#define T_DEV 3
#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_CREATE 0x200
#define O_TRUNC 0x400
#define CONSOLE 1

int fork(void);
void exit(int);
int wait(int*);
int pipe(int*);
int write(int, char*, int);
int read(int, char*, int);
int close(int);
int kill(int);
int exec(char*, char**);
int open(char*, int);
int mknod(char*, int);
int unlink(char*);
int fstat(int, struct stat*);
int mkdir(char*);
int chdir(char*);
int dup(int);
int getpid(void);
char *sbrk(int);

int print(char*, ...);
int sprint(char*, char*, ...);
void *malloc(ulong);
void free(void*);
long strlen(char*);
char *strcpy(char*, char*);
int strcmp(char*, char*);
void *memset(void*, int, ulong);
int atoi(char*);

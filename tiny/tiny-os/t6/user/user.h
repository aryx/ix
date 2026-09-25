// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// What a program of t6 has: its system calls (sys.tm, and start.tm's
// write and exits) and libc (../../libc/).

typedef unsigned int uint;
typedef unsigned long ulong;

// a directory's entry, as read from it
struct dirent { char name[20]; int type; uint first; uint size; };

#define T_DIR 1
#define T_FILE 2
#define T_DEV 3
#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_CREATE 0x200
#define O_TRUNC 0x400

void exit(int);
int write(int, char*, int);
int read(int, char*, int);
// a new process running path, argv its arguments; its descriptors 0, 1
// and 2 are the caller's map[0], map[1], map[2] (-1: none), and it has
// no other; its pid
int spawn(char *path, char **argv, int *map);
int wait(int*);
int getpid(void);
char *sbrk(int);
int open(char*, int);
int close(int);
int pipe(int*);
int mkdir(char*);
int unlink(char*);
int chdir(char*);
int tickets(int);

int print(char*, ...);
int sprint(char*, char*, ...);
void *malloc(ulong);
void free(void*);
long strlen(char*);
char *strcpy(char*, char*);
int strcmp(char*, char*);
void *memset(void*, int, ulong);
int atoi(char*);

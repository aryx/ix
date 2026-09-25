// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// t6, tiny-os's free kernel: its types, constants and prototypes.

typedef unsigned int uint;

// the memory: the kernel in the first MB, a partition of 1 MB for each
// process above it (its window: a user address plus its base), the
// devices at the top
#define PART 0x100000
#define NPROC 14
#define NFD 8
#define STACK 0x10000
#define CONS_OUT 0xfffffff0
#define HALT 0xfffffff4
#define CONS_IN 0xfffffff8
#define DISK_BLOCK 0xffffffe0
#define DISK_ADDR 0xffffffe4
#define DISK_CMD 0xffffffe8
#define DISK_STATUS 0xffffffec

// the registers of control's values (TinyMachine.ml)
#define C_SYS 1
#define C_INTR 4
#define I_TIMER 1
#define I_CONSOLE 2
#define TICK 20000

// what a system call returns when it must wait: its caller's pc goes
// back to its sys, which runs again when the caller is woken
#define BLOCKED 0x7ffffff0

// the disk (TinyMkfs.ml's -fat)
#define BSIZE 1024
#define NBLOCKS 2048
#define FATMAGIC 0x7f5f0006
#define FATEND 0xffffffff
#define T_DIR 1
#define T_FILE 2
#define T_DEV 3
#define O_WRONLY 1
#define O_RDWR 2
#define O_CREATE 0x200
#define O_TRUNC 0x400

struct dirent { char name[20]; int type; uint first; uint size; };

enum { FREE, READY, WAITING, ZOMBIE };

// r first, then pc: entry.tm saves the user's registers there (r[k] is
// rk) and the pc at 64
struct proc {
	uint r[16];
	uint pc;
	int state;
	void *chan;
	int pid;
	struct proc *parent;
	int xstate;
	uint brk;
	int tickets;
	struct file *fd[NFD];
	char cwd[64];
	char name[16];
};

enum { F_NONE, F_FILE, F_DIR, F_CONS, F_PIPER, F_PIPEW };

struct pipe { char buf[512]; uint r; uint w; int readers; int writers; };

// an open file: its entry's place on the disk (to keep its size and first
// block), where it is read or written
struct file {
	int type;
	int ref;
	int writable;
	uint entblock;
	uint entoff;
	uint first;
	uint size;
	uint off;
	struct pipe *pipe;
};

// entry.tm
void trapvec(void);
void resume(struct proc *p);
uint r_cause(void);
uint r_tval(void);
uint r_time(void);
void w_timecmp(uint v);
void w_tvec(uint v);
void w_ie(uint v);
void w_base(uint v);
void w_bound(uint v);
void intr_on(void);
void intr_off(void);
void memzero(void *p, uint n);

// main.c
void printf(char *fmt, ...);
void panic(char *s);
void halt(int status);
void *memset(void *p, int c, uint n);
void *memmove(void *d, void *s, uint n);
int strcmp(char *a, char *b);
int strlen(char *s);
char *strcpy(char *d, char *s);

// proc.c
extern struct proc proc[NPROC];
extern struct proc *cur;
int block(void *chan);
void wakeup(void *chan);
uint uaddr(struct proc *p, uint va, uint n);

// file.c
void fsinit(void);
void consoleintr(void);
struct file *fileopen(char *path, int mode, struct proc *p);
struct file *filedup(struct file *f);
void fileclose(struct file *f);
int fileread(struct file *f, char *dst, uint n);
int filewrite(struct file *f, char *src, uint n);
int sys_open(void);
int sys_close(void);
int sys_read(void);
int sys_write(void);
int sys_pipe(void);
int sys_mkdir(void);
int sys_unlink(void);
int sys_chdir(void);

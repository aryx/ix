// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// tiny-os v6: the types, the constants and the prototypes, in one header
// (xv6's types.h, param.h, memlayout.h, riscv.h, spinlock.h, proc.h,
// fs.h, file.h, stat.h, fcntl.h and defs.h). tiny-c has no macro with
// arguments, so what xv6 writes as one (PGROUNDUP, PX) is a function.

typedef unsigned int uint;
typedef unsigned char uchar;
typedef uint pte_t;
typedef uint *pagetable_t;

// the memory: the kernel identity-mapped at the bottom (where the
// machine starts), a process's space above it, the devices' page at the
// top of the addresses (the machine's registers at its end: -16(r0))
#define PGSIZE 4096
#define KERNTOP 0x800000
#define USERBASE 0x800000
#define USERTOP 0x1000000
#define DEVPAGE 0xfffff000
#define DEVPHYS 0xfff000
#define CONS_OUT 0xfffffff0
#define HALT 0xfffffff4
#define CONS_IN 0xfffffff8
#define DISK_BLOCK 0xffffffe0
#define DISK_ADDR 0xffffffe4
#define DISK_CMD 0xffffffe8
#define DISK_STATUS 0xffffffec

// Sv32's page table entries (TinyMachine.ml)
#define PTE_V 1
#define PTE_R 2
#define PTE_W 4
#define PTE_X 8
#define PTE_U 16
#define SATP_ON 0x80000000

// the registers of control's bits (TinyMachine.ml)
#define S_SUPER 1
#define S_IE 2
#define I_TIMER 1
#define I_CONSOLE 2
#define C_SYS 1
#define C_ILLEGAL 2
#define C_FAULT 3
#define C_INTR 4

#define NCPU 1
#define NPROC 16
#define NOFILE 16
#define NFILE 64
#define NINODE 32
#define NBUF 16
#define MAXARG 16
#define MAXPATH 64
#define TICK 20000

// the file system's format (TinyMkfs.ml's)
#define BSIZE 1024
#define FSMAGIC 0x7f5f0001
#define NDIRECT 12
#define NINDIRECT 256
#define DIRSIZ 12
#define ROOTINO 1
#define T_DIR 1
#define T_FILE 2
#define T_DEV 3
#define CONSOLE 1

struct superblock { uint magic, size, ninodes, inodestart, bmapstart, datastart; };
struct dinode { int type; int major; uint size; uint addrs[13]; };
struct dirent { int inum; char name[12]; };
struct stat { int type; int ino; uint size; };

#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_CREATE 0x200
#define O_TRUNC 0x400

// locks, cores, processes
struct spinlock { int locked; char *name; struct cpu *cpu; };

// what swtch saves: tiny-c's callee may use any register, so a
// context is where it stopped and its stack
struct context { uint sp; uint lr; };

struct cpu {
	struct proc *proc;
	struct context context;
	int noff;
	int intena;
};

enum procstate { UNUSED, EMBRYO, SLEEPING, RUNNABLE, RUNNING, ZOMBIE };

// tf first: entry.tm saves the registers there (tf[k] is rk), the pc
// at tf[16], and finds the kernel's stack at tf[17]
struct proc {
	uint tf[18];
	struct context context;
	enum procstate state;
	int pid;
	int killed;
	int xstate;
	void *chan;
	struct proc *parent;
	pagetable_t pagetable;
	uint sz;
	char *kstack;
	struct file *ofile[NOFILE];
	struct inode *cwd;
	char name[16];
};

// files
struct buf { int valid; int busy; uint blockno; uint used; uchar data[BSIZE]; };
struct inode { uint inum; int ref; int busy; int valid; int gone; int type; int major; uint size; uint addrs[13]; };
struct pipe { struct spinlock lock; char data[512]; uint nread; uint nwrite; int readopen; int writeopen; };
enum { FD_NONE, FD_PIPE, FD_INODE, FD_DEVICE };
struct file { int type; int ref; int readable; int writable; struct pipe *pipe; struct inode *ip; uint off; int major; };
struct devsw { int (*read)(int, uint, int); int (*write)(int, uint, int); };

// entry.tm
extern char end[];
void trapvec(void);
void userret(uint *tf);
void swtch(struct context *old, struct context *new);
int amoswap(int *p, int v);
int r_hartid(void);
uint r_time(void);
uint r_cause(void);
uint r_tval(void);
uint r_ip(void);
void w_timecmp(uint v);
void w_satp(uint v);
void w_tvec(uint v);
void w_ie(uint v);
int intr_get(void);
void intr_on(void);
void intr_off(void);

// main.c
extern struct cpu cpus[NCPU];
void printf(char *fmt, ...);
void panic(char *s);
void halt(int status);
void consputc(int c);
void *memset(void *p, int c, uint n);
void *memmove(void *d, void *s, uint n);
int strncmp(char *a, char *b, uint n);
char *safestrcpy(char *d, char *s, int n);
int strlen(char *s);
void *kalloc(void);
void kfree(void *pa);
int kfreecount(void);
void initlock(struct spinlock *lk, char *name);
void acquire(struct spinlock *lk);
void release(struct spinlock *lk);
int holding(struct spinlock *lk);
void push_off(void);
void pop_off(void);
struct cpu *mycpu(void);
struct proc *myproc(void);
uint pgroundup(uint a);
uint pgrounddown(uint a);

// vm.c
extern pagetable_t kernel_pagetable;
void kvminit(void);
uint *walk(pagetable_t pt, uint va, int alloc);
int mappages(pagetable_t pt, uint va, uint size, uint pa, int perm);
uint walkaddr(pagetable_t pt, uint va);
pagetable_t uvmcreate(void);
uint uvmalloc(pagetable_t pt, uint oldsz, uint newsz);
void uvmunmap(pagetable_t pt, uint from, uint to);
void uvmfree(pagetable_t pt, uint sz);
int uvmcopy(pagetable_t old, pagetable_t new, uint sz);
int copyout(pagetable_t pt, uint dstva, char *src, uint len);
int copyin(pagetable_t pt, char *dst, uint srcva, uint len);
int copyinstr(pagetable_t pt, char *dst, uint srcva, uint max);

// proc.c
void procinit(void);
void userinit(void);
void scheduler(void);
void sched(void);
void yield(void);
void forkret(void);
void sleep(void *chan, struct spinlock *lk);
void wakeup(void *chan);
void exit(int status);
int fork(void);
int wait(uint addr);
int kill(int pid);
void usertrap(void);
void usertrapret(void);
void kerneltrap(void);
void syscall(uint n);
int argint(int n);
int argstr(int n, char *buf, int max);

// fs.c
extern struct spinlock icache_lock;
void fsinit(void);
struct inode *iget(uint inum);
struct inode *idup(struct inode *ip);
void ilock(struct inode *ip);
void iunlock(struct inode *ip);
void iput(struct inode *ip);
void iunlockput(struct inode *ip);
void iupdate(struct inode *ip);
void itrunc(struct inode *ip);
struct inode *ialloc(int type);
void stati(struct inode *ip, struct stat *st);
int readi(struct inode *ip, int user, uint dst, uint off, uint n);
int writei(struct inode *ip, int user, uint src, uint off, uint n);
int either_copyout(int user, uint dst, char *src, uint n);
int either_copyin(char *dst, int user, uint src, uint n);
struct inode *dirlookup(struct inode *dp, char *name, uint *poff);
int dirlink(struct inode *dp, char *name, uint inum);
struct inode *namei(char *path);
struct inode *nameiparent(char *path, char *name);

// file.c
void fileinit(void);
struct file *filealloc(void);
struct file *filedup(struct file *f);
void fileclose(struct file *f);
int fileread(struct file *f, uint addr, int n);
int filewrite(struct file *f, uint addr, int n);
void pipeclose(struct pipe *pi, int writable);
int pipewrite(struct pipe *pi, uint addr, int n);
int piperead(struct pipe *pi, uint addr, int n);
void consoleintr(void);
int exec(char *path, char **argv);
int sys_read(void);
int sys_write(void);
int sys_exec(void);
int sys_open(void);
int sys_close(void);
int sys_dup(void);
int sys_pipe(void);
int sys_fstat(void);
int sys_chdir(void);
int sys_mkdir(void);
int sys_unlink(void);
int sys_mknod(void);

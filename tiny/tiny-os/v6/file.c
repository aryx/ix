// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// tiny-os v6: the files a process holds (xv6's file.c, pipe.c,
// console.c, exec.c and sysfile.c; the ideas: main.c): the open files' table, pipes, the
// console (a device, reached through devsw's function pointers), exec
// of an a.out, and the system calls on files.
#include "defs.h"

struct devsw devsw[4];
struct file ftable[NFILE];
struct spinlock ftable_lock;

struct file*
filealloc(void)
{
	struct file *f;

	acquire(&ftable_lock);
	for(f = ftable; f < &ftable[NFILE]; f++)
		if(f->ref == 0){
			f->ref = 1;
			release(&ftable_lock);
			return f;
		}
	release(&ftable_lock);
	return 0;
}

struct file*
filedup(struct file *f)
{
	acquire(&ftable_lock);
	f->ref++;
	release(&ftable_lock);
	return f;
}

void
fileclose(struct file *f)
{
	int type;
	struct pipe *pi;
	struct inode *ip;
	int writable;

	acquire(&ftable_lock);
	if(--f->ref > 0){
		release(&ftable_lock);
		return;
	}
	type = f->type;
	pi = f->pipe;
	ip = f->ip;
	writable = f->writable;
	f->type = FD_NONE;
	release(&ftable_lock);
	if(type == FD_PIPE)
		pipeclose(pi, writable);
	else if(type == FD_INODE || type == FD_DEVICE)
		iput(ip);
}

int
fileread(struct file *f, uint addr, int n)
{
	int r;

	if(!f->readable)
		return -1;
	if(f->type == FD_PIPE)
		return piperead(f->pipe, addr, n);
	if(f->type == FD_DEVICE)
		return devsw[f->major].read(1, addr, n);
	ilock(f->ip);
	if((r = readi(f->ip, 1, addr, f->off, n)) > 0)
		f->off += r;
	iunlock(f->ip);
	return r;
}

int
filewrite(struct file *f, uint addr, int n)
{
	int r;

	if(!f->writable)
		return -1;
	if(f->type == FD_PIPE)
		return pipewrite(f->pipe, addr, n);
	if(f->type == FD_DEVICE)
		return devsw[f->major].write(1, addr, n);
	ilock(f->ip);
	if((r = writei(f->ip, 1, addr, f->off, n)) > 0)
		f->off += r;
	iunlock(f->ip);
	return r;
}

// ---------------------------------------------------------------- pipes

int
pipealloc(struct file **f0, struct file **f1)
{
	struct pipe *pi;

	if((*f0 = filealloc()) == 0 || (*f1 = filealloc()) == 0 || (pi = kalloc()) == 0){
		if(*f0)
			fileclose(*f0);
		if(*f1)
			fileclose(*f1);
		return -1;
	}
	initlock(&pi->lock, "pipe");
	pi->nread = pi->nwrite = 0;
	pi->readopen = pi->writeopen = 1;
	(*f0)->type = (*f1)->type = FD_PIPE;
	(*f0)->pipe = (*f1)->pipe = pi;
	(*f0)->readable = 1;
	(*f0)->writable = 0;
	(*f1)->readable = 0;
	(*f1)->writable = 1;
	return 0;
}

void
pipeclose(struct pipe *pi, int writable)
{
	acquire(&pi->lock);
	if(writable){
		pi->writeopen = 0;
		wakeup(&pi->nread);
	} else {
		pi->readopen = 0;
		wakeup(&pi->nwrite);
	}
	if(pi->readopen == 0 && pi->writeopen == 0){
		release(&pi->lock);
		kfree(pi);
	} else
		release(&pi->lock);
}

int
pipewrite(struct pipe *pi, uint addr, int n)
{
	int i;
	char c;

	acquire(&pi->lock);
	for(i = 0; i < n; i++){
		while(pi->nwrite == pi->nread + 512){
			if(!pi->readopen || myproc()->killed){
				release(&pi->lock);
				return -1;
			}
			wakeup(&pi->nread);
			sleep(&pi->nwrite, &pi->lock);
		}
		if(copyin(myproc()->pagetable, &c, addr + i, 1) < 0)
			break;
		pi->data[pi->nwrite++ % 512] = c;
	}
	wakeup(&pi->nread);
	release(&pi->lock);
	return i;
}

int
piperead(struct pipe *pi, uint addr, int n)
{
	int i;
	char c;

	acquire(&pi->lock);
	while(pi->nread == pi->nwrite && pi->writeopen){
		if(myproc()->killed){
			release(&pi->lock);
			return -1;
		}
		sleep(&pi->nread, &pi->lock);
	}
	for(i = 0; i < n && pi->nread != pi->nwrite; i++){
		c = pi->data[pi->nread++ % 512];
		if(copyout(myproc()->pagetable, addr + i, &c, 1) < 0)
			break;
	}
	wakeup(&pi->nwrite);
	release(&pi->lock);
	return i;
}

// ---------------------------------------------------------------- the console

// its input by lines: the interrupt takes the machine's bytes, a read
// waits for a line (or the input's end); its output byte by byte
struct spinlock cons_lock;
char cons_buf[128];
uint cons_r, cons_w;
int cons_eof;

void
consoleintr(void)
{
	uint c;

	acquire(&cons_lock);
	for(;;){
		c = *(uint*)CONS_IN;
		if(c == 0xffffffff)
			break;
		if(c == 0xfffffffe){
			cons_eof = 1;
			break;
		}
		if(cons_w - cons_r < 128)
			cons_buf[cons_w++ % 128] = c;
	}
	wakeup(&cons_r);
	release(&cons_lock);
}

int
consoleread(int user, uint dst, int n)
{
	int got;
	char c;

	acquire(&cons_lock);
	for(got = 0; got < n; ){
		while(cons_r == cons_w){
			if(cons_eof || myproc()->killed){
				release(&cons_lock);
				return got;
			}
			sleep(&cons_r, &cons_lock);
		}
		c = cons_buf[cons_r++ % 128];
		if(either_copyout(user, dst + got, &c, 1) < 0)
			break;
		got++;
		if(c == '\n')
			break;
	}
	release(&cons_lock);
	return got;
}

int
consolewrite(int user, uint src, int n)
{
	int i;
	char c;

	for(i = 0; i < n; i++){
		if(either_copyin(&c, user, src + i, 1) < 0)
			break;
		consputc(c);
	}
	return i;
}

void
fileinit(void)
{
	initlock(&ftable_lock, "ftable");
	initlock(&cons_lock, "cons");
	devsw[CONSOLE].read = consoleread;
	devsw[CONSOLE].write = consolewrite;
}

// ---------------------------------------------------------------- exec

// exec's failure: what it made undone
int
execfail(struct inode *ip, pagetable_t pt, uint sz)
{
	if(ip)
		iunlockput(ip);
	if(pt)
		uvmfree(pt, sz);
	return -1;
}

// an a.out (TinyLibCPU's aout: a magic, the size, the entry, then the
// image, linked at USERBASE) in place of the process's program; its
// stack as tiny-cpu leaves one, where start.tm finds main's arguments:
// argc at sp, argv at sp + 4, the pointers and the strings above
int
exec(char *path, char **argv)
{
	struct inode *ip;
	uint hdr[3], sz, sp, a, pa, n, ustack[MAXARG + 3];
	int argc;
	pagetable_t pt, old;
	struct proc *p;

	p = myproc();
	if((ip = namei(path)) == 0)
		return -1;
	ilock(ip);
	if(readi(ip, 0, (uint)hdr, 0, 12) != 12 || hdr[0] != 0x7a0ce5)
		return execfail(ip, 0, 0);
	if((pt = uvmcreate()) == 0)
		return execfail(ip, 0, 0);
	if((sz = uvmalloc(pt, 0, hdr[1])) == 0)
		return execfail(ip, pt, 0);
	for(a = 0; a < sz; a += PGSIZE){
		pa = walkaddr(pt, USERBASE + a);
		n = PGSIZE;
		if(sz - a < PGSIZE)
			n = sz - a;
		if(readi(ip, 0, pa, 12 + a, n) != n)
			return execfail(ip, pt, sz);
	}
	iunlockput(ip);
	// the arguments' strings from the top down, then the pointers
	sp = USERTOP;
	for(argc = 0; argv[argc]; argc++){
		if(argc >= MAXARG)
			return execfail(0, pt, sz);
		sp = (sp - strlen(argv[argc]) - 1) & ~3;
		if(copyout(pt, sp, argv[argc], strlen(argv[argc]) + 1) < 0)
			return execfail(0, pt, sz);
		ustack[2 + argc] = sp;
	}
	ustack[2 + argc] = 0;
	sp = (sp - (argc + 3) * 4) & ~7;
	ustack[0] = argc;
	ustack[1] = sp + 8;
	if(copyout(pt, sp, (char*)ustack, (argc + 3) * 4) < 0)
		return execfail(0, pt, sz);
	safestrcpy(p->name, path, 16);
	old = p->pagetable;
	p->pagetable = pt;
	w_satp(SATP_ON | ((uint)pt >> 12));
	uvmfree(old, p->sz);
	p->sz = sz;
	p->tf[16] = hdr[2];
	p->tf[14] = sp;
	return argc;
}

// ---------------------------------------------------------------- the system calls on files

// the file of the n-th argument's descriptor
struct file*
argfd(int n, int *pfd)
{
	int fd;
	struct file *f;

	fd = argint(n);
	if(fd < 0 || fd >= NOFILE || (f = myproc()->ofile[fd]) == 0)
		return 0;
	if(pfd)
		*pfd = fd;
	return f;
}

int
fdalloc(struct file *f)
{
	int fd;
	struct proc *p;

	p = myproc();
	for(fd = 0; fd < NOFILE; fd++)
		if(p->ofile[fd] == 0){
			p->ofile[fd] = f;
			return fd;
		}
	return -1;
}

int
sys_read(void)
{
	struct file *f;

	if((f = argfd(0, 0)) == 0)
		return -1;
	return fileread(f, argint(1), argint(2));
}

int
sys_write(void)
{
	struct file *f;

	if((f = argfd(0, 0)) == 0)
		return -1;
	return filewrite(f, argint(1), argint(2));
}

int
sys_close(void)
{
	int fd;
	struct file *f;

	if((f = argfd(0, &fd)) == 0)
		return -1;
	myproc()->ofile[fd] = 0;
	fileclose(f);
	return 0;
}

int
sys_dup(void)
{
	struct file *f;
	int fd;

	if((f = argfd(0, 0)) == 0 || (fd = fdalloc(f)) < 0)
		return -1;
	filedup(f);
	return fd;
}

int
sys_fstat(void)
{
	struct file *f;
	struct stat st;

	if((f = argfd(0, 0)) == 0 || f->type == FD_PIPE)
		return -1;
	ilock(f->ip);
	stati(f->ip, &st);
	iunlock(f->ip);
	return copyout(myproc()->pagetable, argint(1), (char*)&st, sizeof st);
}

// a new inode at path, of a type, locked; or the file there, if it is
// one and a file was asked for
struct inode*
create(char *path, int type, int major)
{
	struct inode *ip, *dp;
	char name[DIRSIZ + 1];

	if((dp = nameiparent(path, name)) == 0)
		return 0;
	ilock(dp);
	if((ip = dirlookup(dp, name, 0)) != 0){
		iunlockput(dp);
		ilock(ip);
		if(type == T_FILE && ip->type != T_DIR)
			return ip;
		iunlockput(ip);
		return 0;
	}
	ip = ialloc(type);
	ilock(ip);
	ip->major = major;
	iupdate(ip);
	if(type == T_DIR && (dirlink(ip, ".", ip->inum) < 0 || dirlink(ip, "..", dp->inum) < 0))
		panic("create: dots");
	if(dirlink(dp, name, ip->inum) < 0)
		panic("create: dirlink");
	iunlockput(dp);
	return ip;
}

int
sys_open(void)
{
	char path[MAXPATH];
	int fd, mode;
	struct file *f;
	struct inode *ip;

	if(argstr(0, path, MAXPATH) < 0)
		return -1;
	mode = argint(1);
	if(mode & O_CREATE){
		if((ip = create(path, T_FILE, 0)) == 0)
			return -1;
	} else {
		if((ip = namei(path)) == 0)
			return -1;
		ilock(ip);
		if(ip->type == T_DIR && mode != O_RDONLY){
			iunlockput(ip);
			return -1;
		}
	}
	if((f = filealloc()) == 0 || (fd = fdalloc(f)) < 0){
		if(f)
			fileclose(f);
		iunlockput(ip);
		return -1;
	}
	if(ip->type == T_DEV){
		f->type = FD_DEVICE;
		f->major = ip->major;
	} else
		f->type = FD_INODE;
	f->ip = ip;
	f->off = 0;
	f->readable = !(mode & O_WRONLY);
	f->writable = (mode & O_WRONLY) || (mode & O_RDWR);
	if((mode & O_TRUNC) && ip->type == T_FILE)
		itrunc(ip);
	iunlock(ip);
	return fd;
}

int
sys_mkdir(void)
{
	char path[MAXPATH];
	struct inode *ip;

	if(argstr(0, path, MAXPATH) < 0 || (ip = create(path, T_DIR, 0)) == 0)
		return -1;
	iunlockput(ip);
	return 0;
}

int
sys_mknod(void)
{
	char path[MAXPATH];
	struct inode *ip;

	if(argstr(0, path, MAXPATH) < 0 || (ip = create(path, T_DEV, argint(1))) == 0)
		return -1;
	iunlockput(ip);
	return 0;
}

int
sys_chdir(void)
{
	char path[MAXPATH];
	struct inode *ip;
	struct proc *p;

	p = myproc();
	if(argstr(0, path, MAXPATH) < 0 || (ip = namei(path)) == 0)
		return -1;
	ilock(ip);
	if(ip->type != T_DIR){
		iunlockput(ip);
		return -1;
	}
	iunlock(ip);
	iput(p->cwd);
	p->cwd = ip;
	return 0;
}

// a name removed; its inode freed by its last iput (no links: a name is
// a file's only one); a directory only if empty
int
sys_unlink(void)
{
	char path[MAXPATH], name[DIRSIZ + 1];
	struct inode *ip, *dp;
	struct dirent de;
	uint off, o;

	if(argstr(0, path, MAXPATH) < 0 || (dp = nameiparent(path, name)) == 0)
		return -1;
	ilock(dp);
	if(strncmp(name, ".", DIRSIZ) == 0 || strncmp(name, "..", DIRSIZ) == 0 || (ip = dirlookup(dp, name, &off)) == 0){
		iunlockput(dp);
		return -1;
	}
	ilock(ip);
	if(ip->type == T_DIR)
		for(o = 2 * sizeof de; o < ip->size; o += sizeof de){
			readi(ip, 0, (uint)&de, o, sizeof de);
			if(de.inum != 0){
				iunlockput(ip);
				iunlockput(dp);
				return -1;
			}
		}
	memset(&de, 0, sizeof de);
	writei(dp, 0, (uint)&de, off, sizeof de);
	iunlockput(dp);
	ip->gone = 1;
	iunlockput(ip);
	return 0;
}

int
sys_pipe(void)
{
	struct file *rf, *wf;
	int fd[2];
	struct proc *p;

	p = myproc();
	rf = wf = 0;
	if(pipealloc(&rf, &wf) < 0)
		return -1;
	fd[0] = fdalloc(rf);
	fd[1] = fdalloc(wf);
	if(fd[0] < 0 || fd[1] < 0 || copyout(p->pagetable, argint(0), (char*)fd, 8) < 0){
		if(fd[0] >= 0)
			p->ofile[fd[0]] = 0;
		if(fd[1] >= 0)
			p->ofile[fd[1]] = 0;
		fileclose(rf);
		fileclose(wf);
		return -1;
	}
	return 0;
}

// exec(path, argv): the path and the argument strings copied into the
// kernel, a page for them all
int
sys_exec(void)
{
	char path[MAXPATH], *argv[MAXARG + 1], *page;
	uint uargv, uarg;
	int i, n, r;

	if(argstr(0, path, MAXPATH) < 0 || (page = kalloc()) == 0)
		return -1;
	uargv = argint(1);
	n = 0;
	for(i = 0; ; i++){
		if(i >= MAXARG){
			kfree(page);
			return -1;
		}
		uarg = 0;
		if(uargv != 0 && copyin(myproc()->pagetable, (char*)&uarg, uargv + 4 * i, 4) < 0){
			kfree(page);
			return -1;
		}
		if(uarg == 0)
			break;
		argv[i] = page + n;
		if(copyinstr(myproc()->pagetable, argv[i], uarg, PGSIZE - n) < 0){
			kfree(page);
			return -1;
		}
		n += strlen(argv[i]) + 1;
	}
	argv[i] = 0;
	r = exec(path, argv);
	kfree(page);
	return r;
}

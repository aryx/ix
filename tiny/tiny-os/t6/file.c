// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// t6: the files, on a FAT (MS-DOS's idea; TinyMkfs.ml's -fat): the disk
// is blocks, a table in memory gives each block's next, a file is its
// directory entry (a name, a type, its first block, its size), a
// directory a file of entries. No inodes, no buffer cache (the disk is
// instant, and the kernel one thread: one block in memory at a time),
// no "." or "..": a path's ".." is resolved by its text (Plan 9's
// cleanname), and the current directory is a path. Pipes and the
// console are the other files; a read or a write that must wait
// blocks (proc.c) and is run again.
#include "t6.h"

uint fat[NBLOCKS];
uint fatstart, rootblock;
char buf[BSIZE];

void
disk(uint b, char *mem, int write)
{
	*(uint*)DISK_BLOCK = b;
	*(uint*)DISK_ADDR = (uint)mem;
	*(uint*)DISK_CMD = 1 + write;
	while(*(uint*)DISK_STATUS == 0)
		;
	*(uint*)DISK_STATUS = 0;
}

void
fsinit(void)
{
	uint i, *sb;

	disk(0, buf, 0);
	sb = (uint*)buf;
	if(sb[0] != FATMAGIC)
		panic("not a t6 disk");
	fatstart = sb[2];
	rootblock = sb[4];
	for(i = 0; i < sb[3]; i++)
		disk(fatstart + i, (char*)fat + i * BSIZE, 0);
}

// the table changed, and its block on the disk
void
fatset(uint b, uint v)
{
	uint k;

	fat[b] = v;
	k = b / (BSIZE / 4);
	disk(fatstart + k, (char*)fat + k * BSIZE, 1);
}

uint
balloc(void)
{
	uint b;

	for(b = 0; b < NBLOCKS; b++)
		if(fat[b] == 0){
			fatset(b, FATEND);
			memset(buf, 0, BSIZE);
			disk(b, buf, 1);
			return b;
		}
	panic("the disk is full");
	return 0;
}

void
freechain(uint b)
{
	uint next;

	for(; b != 0 && b != FATEND; b = next){
		next = fat[b];
		fatset(b, 0);
	}
}

// the chain's k-th block, made (and linked) if alloc; 0 if none
uint
bmap(uint *first, uint k, int alloc)
{
	uint b;

	if(*first == 0){
		if(!alloc)
			return 0;
		*first = balloc();
	}
	for(b = *first; k > 0; k--){
		if(fat[b] == FATEND){
			if(!alloc)
				return 0;
			fatset(b, balloc());
		}
		b = fat[b];
	}
	return b;
}

// ---------------------------------------------------------------- directories and paths

int
namecmp(char *a, char *entry)
{
	int i;

	for(i = 0; i < 20 && a[i] && a[i] == entry[i]; i++)
		;
	return i < 20 && (a[i] != 0 || entry[i] != 0);
}

// name's entry in the directory from first, and its place
int
lookup(uint first, char *name, struct dirent *e, uint *eb, uint *eo)
{
	uint k, b, o;
	struct dirent *d;

	for(k = 0; (b = bmap(&first, k, 0)) != 0; k++){
		disk(b, buf, 0);
		for(o = 0; o < BSIZE; o += sizeof *d){
			d = (struct dirent*)(buf + o);
			if(d->type != 0 && namecmp(name, d->name) == 0){
				memmove(e, d, sizeof *d);
				*eb = b;
				*eo = o;
				return 0;
			}
		}
	}
	return -1;
}

void
writeent(uint eb, uint eo, struct dirent *e)
{
	disk(eb, buf, 0);
	memmove(buf + eo, e, sizeof *e);
	disk(eb, buf, 1);
}

// e in a free place of the directory from first (a new block if full)
void
addent(uint first, struct dirent *e, uint *eb, uint *eo)
{
	uint k, b, o;

	for(k = 0; ; k++){
		b = bmap(&first, k, 1);
		disk(b, buf, 0);
		for(o = 0; o < BSIZE; o += sizeof *e)
			if(((struct dirent*)(buf + o))->type == 0){
				writeent(b, o, e);
				*eb = b;
				*eo = o;
				return;
			}
	}
}

// the path's names, cleaned by their text: its own ones, or the current
// directory's first; "." dropped, ".." the name before it removed
int
split(struct proc *p, char *path, char *full, char **names)
{
	char *s;
	int n;

	if(path[0] == '/' || strlen(p->cwd) + strlen(path) + 2 > 128)
		strcpy(full, path);
	else {
		strcpy(full, p->cwd);
		strcpy(full + strlen(full), "/");
		strcpy(full + strlen(full), path);
	}
	n = 0;
	for(s = full; ; ){
		while(*s == '/')
			*s++ = 0;
		if(*s == 0)
			break;
		names[n] = s;
		while(*s && *s != '/')
			s++;
		if(*s)
			*s++ = 0;
		if(strcmp(names[n], "..") == 0){
			if(n > 0)
				n--;
		} else if(strcmp(names[n], ".") != 0 && n < 15)
			n++;
	}
	return n;
}

// the path's entry and its place; its directory's first block in *dir.
// 0 if found; -1 if not, its name in last (where create puts it); -2 if
// a directory on the way is missing
int
walk(struct proc *p, char *path, struct dirent *e, uint *eb, uint *eo, uint *dir, char *last)
{
	char full[128], *names[16];
	int n, i;

	n = split(p, path, full, names);
	*dir = rootblock;
	memset(e, 0, sizeof *e);
	e->type = T_DIR;
	e->first = rootblock;
	*eb = *eo = 0;
	for(i = 0; i < n; i++){
		if(e->type != T_DIR)
			return -2;
		*dir = e->first;
		if(lookup(*dir, names[i], e, eb, eo) < 0){
			if(i < n - 1 || strlen(names[i]) > 19)
				return -2;
			strcpy(last, names[i]);
			return -1;
		}
	}
	return 0;
}

// ---------------------------------------------------------------- open files

struct file files[64];
struct pipe pipes[16];

struct file*
falloc(void)
{
	struct file *f;

	for(f = files; f < &files[64]; f++)
		if(f->ref == 0){
			memset(f, 0, sizeof *f);
			f->ref = 1;
			return f;
		}
	return 0;
}

struct file*
filedup(struct file *f)
{
	f->ref++;
	return f;
}

void
fileclose(struct file *f)
{
	if(--f->ref > 0)
		return;
	if(f->type == F_PIPER){
		f->pipe->readers--;
		wakeup(&f->pipe->w);
	} else if(f->type == F_PIPEW){
		f->pipe->writers--;
		wakeup(&f->pipe->r);
	}
	f->type = F_NONE;
}

int
chainlen(uint first)
{
	int n;

	for(n = 0; bmap(&first, n, 0) != 0; n++)
		;
	return n;
}

struct file*
fileopen(char *path, int mode, struct proc *p)
{
	struct dirent e;
	uint eb, eo, dir;
	char name[20];
	int r;
	struct file *f;

	r = walk(p, path, &e, &eb, &eo, &dir, name);
	if(r == -1 && (mode & O_CREATE)){
		memset(&e, 0, sizeof e);
		strcpy(e.name, name);
		e.type = T_FILE;
		addent(dir, &e, &eb, &eo);
		r = 0;
	}
	if(r < 0 || (e.type == T_DIR && (mode & (O_WRONLY | O_RDWR))) || (f = falloc()) == 0)
		return 0;
	if((mode & O_TRUNC) && e.type == T_FILE){
		freechain(e.first);
		e.first = e.size = 0;
		writeent(eb, eo, &e);
	}
	f->type = e.type == T_DIR ? F_DIR : e.type == T_DEV ? F_CONS : F_FILE;
	f->entblock = eb;
	f->entoff = eo;
	f->first = e.first;
	f->size = f->type == F_DIR ? chainlen(e.first) * BSIZE : e.size;
	f->writable = (mode & (O_WRONLY | O_RDWR)) != 0;
	return f;
}

// the console's input, by lines; the pipes; the files' blocks. dst and
// src are the kernel's addresses (a user's buffer is contiguous in its
// partition)
int consoleread(char *dst, uint n);
int piperead(struct pipe *pi, char *dst, uint n);
int pipewrite(struct pipe *pi, char *src, uint n);

int
fileread(struct file *f, char *dst, uint n)
{
	uint b, m, tot;

	if(f->type == F_CONS)
		return consoleread(dst, n);
	if(f->type == F_PIPER)
		return piperead(f->pipe, dst, n);
	if(f->type != F_FILE && f->type != F_DIR)
		return -1;
	if(f->off >= f->size)
		return 0;
	if(n > f->size - f->off)
		n = f->size - f->off;
	for(tot = 0; tot < n; tot += m, f->off += m){
		b = bmap(&f->first, f->off / BSIZE, 0);
		disk(b, buf, 0);
		m = BSIZE - f->off % BSIZE;
		if(m > n - tot)
			m = n - tot;
		memmove(dst + tot, buf + f->off % BSIZE, m);
	}
	return n;
}

int
filewrite(struct file *f, char *src, uint n)
{
	uint b, m, tot;
	struct dirent e;
	int i;

	if(!f->writable && f->type != F_CONS && f->type != F_PIPEW)
		return -1;
	if(f->type == F_CONS){
		for(i = 0; i < n; i++)
			*(char*)CONS_OUT = src[i];
		return n;
	}
	if(f->type == F_PIPEW)
		return pipewrite(f->pipe, src, n);
	if(f->type != F_FILE)
		return -1;
	for(tot = 0; tot < n; tot += m, f->off += m){
		b = bmap(&f->first, f->off / BSIZE, 1);
		disk(b, buf, 0);
		m = BSIZE - f->off % BSIZE;
		if(m > n - tot)
			m = n - tot;
		memmove(buf + f->off % BSIZE, src + tot, m);
		disk(b, buf, 1);
	}
	if(f->off > f->size)
		f->size = f->off;
	disk(f->entblock, buf, 0);
	memmove(&e, buf + f->entoff, sizeof e);
	e.first = f->first;
	e.size = f->size;
	writeent(f->entblock, f->entoff, &e);
	return n;
}

// the whole program at path into mem, its size; -1 if none or too big
int
loadfile(struct proc *p, char *path, char *mem, uint max)
{
	struct file *f;
	int n;

	if(p == 0)
		p = &proc[0];
	if((f = fileopen(path, 0, p)) == 0)
		return -1;
	n = -1;
	if(f->type == F_FILE && f->size <= max)
		n = fileread(f, mem, f->size);
	fileclose(f);
	return n;
}

// ---------------------------------------------------------------- pipes and the console

int
pipewrite(struct pipe *pi, char *src, uint n)
{
	uint i;

	if(pi->readers == 0)
		return -1;
	if(pi->w - pi->r == 512)
		return block(&pi->w);
	for(i = 0; i < n && pi->w - pi->r < 512; i++)
		pi->buf[pi->w++ % 512] = src[i];
	wakeup(&pi->r);
	return i;
}

int
piperead(struct pipe *pi, char *dst, uint n)
{
	uint i;

	if(pi->r == pi->w)
		return pi->writers == 0 ? 0 : block(&pi->r);
	for(i = 0; i < n && pi->r != pi->w; i++)
		dst[i] = pi->buf[pi->r++ % 512];
	wakeup(&pi->w);
	return i;
}

char cbuf[128];
uint cr, cw;
int ceof;

void
consoleintr(void)
{
	uint c;

	for(;;){
		c = *(uint*)CONS_IN;
		if(c == 0xffffffff)
			break;
		if(c == 0xfffffffe){
			ceof = 1;
			break;
		}
		if(cw - cr < 128)
			cbuf[cw++ % 128] = c;
	}
	wakeup(&cr);
}

int
consoleread(char *dst, uint n)
{
	uint i;

	if(cr == cw)
		return ceof ? 0 : block(&cr);
	for(i = 0; i < n && cr != cw; ){
		dst[i] = cbuf[cr++ % 128];
		if(dst[i++] == '\n')
			break;
	}
	return i;
}

// ---------------------------------------------------------------- system calls

struct file*
argfd(int n)
{
	uint fd;

	fd = cur->r[1 + n];
	return fd < NFD ? cur->fd[fd] : 0;
}

int
fdalloc(struct file *f)
{
	int fd;

	for(fd = 0; fd < NFD; fd++)
		if(cur->fd[fd] == 0){
			cur->fd[fd] = f;
			return fd;
		}
	fileclose(f);
	return -1;
}

int ustr(struct proc *p, uint va, char *dst, int max);

int
sys_open(void)
{
	char path[64];
	struct file *f;

	if(ustr(cur, cur->r[1], path, 64) < 0 || (f = fileopen(path, cur->r[2], cur)) == 0)
		return -1;
	return fdalloc(f);
}

int
sys_close(void)
{
	struct file *f;

	if((f = argfd(0)) == 0)
		return -1;
	cur->fd[cur->r[1]] = 0;
	fileclose(f);
	return 0;
}

int
sys_read(void)
{
	struct file *f;
	uint a;

	if((f = argfd(0)) == 0 || (a = uaddr(cur, cur->r[2], cur->r[3])) == 0)
		return -1;
	return fileread(f, (char*)a, cur->r[3]);
}

int
sys_write(void)
{
	struct file *f;
	uint a;

	if((f = argfd(0)) == 0 || (a = uaddr(cur, cur->r[2], cur->r[3])) == 0)
		return -1;
	return filewrite(f, (char*)a, cur->r[3]);
}

int
sys_pipe(void)
{
	struct pipe *pi;
	struct file *r, *w;
	uint a;
	int *fds;

	if((a = uaddr(cur, cur->r[1], 8)) == 0)
		return -1;
	for(pi = pipes; pi < &pipes[16] && (pi->readers || pi->writers); pi++)
		;
	if(pi == &pipes[16] || (r = falloc()) == 0)
		return -1;
	if((w = falloc()) == 0){
		fileclose(r);
		return -1;
	}
	pi->r = pi->w = 0;
	pi->readers = pi->writers = 1;
	r->type = F_PIPER;
	w->type = F_PIPEW;
	r->pipe = w->pipe = pi;
	fds = (int*)a;
	fds[0] = fdalloc(r);
	fds[1] = fdalloc(w);
	return fds[0] < 0 || fds[1] < 0 ? -1 : 0;
}

int
sys_mkdir(void)
{
	char path[64], name[20];
	struct dirent e;
	uint eb, eo, dir;

	if(ustr(cur, cur->r[1], path, 64) < 0 || walk(cur, path, &e, &eb, &eo, &dir, name) != -1)
		return -1;
	memset(&e, 0, sizeof e);
	strcpy(e.name, name);
	e.type = T_DIR;
	e.first = balloc();
	addent(dir, &e, &eb, &eo);
	return 0;
}

// a name removed, and its blocks; a directory only if empty
int
sys_unlink(void)
{
	char path[64], name[20];
	struct dirent e, d;
	uint eb, eo, dir, k, b, o;

	if(ustr(cur, cur->r[1], path, 64) < 0 || walk(cur, path, &e, &eb, &eo, &dir, name) != 0 || eb == 0)
		return -1;
	if(e.type == T_DIR)
		for(k = 0; (b = bmap(&e.first, k, 0)) != 0; k++){
			disk(b, buf, 0);
			for(o = 0; o < BSIZE; o += sizeof d)
				if(((struct dirent*)(buf + o))->type != 0)
					return -1;
		}
	freechain(e.first);
	e.type = 0;
	writeent(eb, eo, &e);
	return 0;
}

// the current directory, a path: the names cleaned, joined again
int
sys_chdir(void)
{
	char path[64], full[128], *names[16], name[20];
	struct dirent e;
	uint eb, eo, dir;
	int n, i;

	if(ustr(cur, cur->r[1], path, 64) < 0 || walk(cur, path, &e, &eb, &eo, &dir, name) != 0 || e.type != T_DIR)
		return -1;
	n = split(cur, path, full, names);
	strcpy(cur->cwd, "/");
	for(i = 0; i < n; i++){
		if(strlen(cur->cwd) + strlen(names[i]) + 2 > 64)
			return -1;
		if(i > 0)
			strcpy(cur->cwd + strlen(cur->cwd), "/");
		strcpy(cur->cwd + strlen(cur->cwd), names[i]);
	}
	return 0;
}

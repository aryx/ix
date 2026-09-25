// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// tiny-os v6: the file system (xv6's virtio_disk.c, bio.c, fs.c, less
// the log), on the format TinyMkfs.ml makes: a superblock, the inodes,
// a bitmap, the data. The layers, from the bottom: the disk's blocks;
// the buffer cache (a block in memory, one process at a time); the
// inodes (a file's blocks, its size); the directories (names to
// inodes); the paths. No log: a crash between two writes may leave the
// disk inconsistent, as Unix's was before fsck.
#include "defs.h"

struct superblock sb;

// the inodes in use, in memory: ref counts the pointers to one; busy is
// its lock (ilock); valid says its fields were read from the disk; gone
// that its name was unlinked, so that the last iput frees it
struct inode inodes[NINODE];
struct spinlock icache_lock;

// the disk, polled: tiny-machine moves the block at once, so there is
// nothing to sleep for (its interrupt is not enabled)
void
diskrw(struct buf *b, int write)
{
	*(uint*)DISK_BLOCK = b->blockno;
	*(uint*)DISK_ADDR = (uint)b->data;
	*(uint*)DISK_CMD = 1 + write;
	while(*(uint*)DISK_STATUS == 0)
		;
	*(uint*)DISK_STATUS = 0;
}

// ---------------------------------------------------------------- the buffer cache

struct buf bcache[NBUF];
struct spinlock bcache_lock;
uint bclock;

// the block's buffer, busy: this process's until brelse
struct buf*
bread(uint blockno)
{
	struct buf *b, *lru;

	acquire(&bcache_lock);
	for(;;){
		lru = 0;
		for(b = bcache; b < &bcache[NBUF]; b++){
			if(b->blockno == blockno && (b->valid || b->busy))
				break;
			if(!b->busy && (lru == 0 || b->used < lru->used))
				lru = b;
		}
		if(b < &bcache[NBUF]){
			if(b->busy){
				sleep(b, &bcache_lock);
				continue;
			}
			b->busy = 1;
			release(&bcache_lock);
			return b;
		}
		if(lru == 0)
			panic("bread: no buffers");
		lru->blockno = blockno;
		lru->valid = 0;
		lru->busy = 1;
		release(&bcache_lock);
		diskrw(lru, 0);
		lru->valid = 1;
		return lru;
	}
}

void
bwrite(struct buf *b)
{
	diskrw(b, 1);
}

void
brelse(struct buf *b)
{
	acquire(&bcache_lock);
	b->busy = 0;
	b->used = ++bclock;
	wakeup(b);
	release(&bcache_lock);
}

void
fsinit(void)
{
	struct buf *b;

	initlock(&bcache_lock, "bcache");
	initlock(&icache_lock, "icache");
	b = bread(0);
	memmove((char*)&sb, (char*)b->data, sizeof sb);
	brelse(b);
	if(sb.magic != FSMAGIC)
		panic("not a tiny-os v6 file system");
}

// ---------------------------------------------------------------- blocks

// a free block, zeroed, marked used in the bitmap
uint
balloc(void)
{
	struct buf *b, *z;
	uint n, mask;

	b = bread(sb.bmapstart);
	for(n = sb.datastart; n < sb.size; n++){
		mask = 1 << (n % 8);
		if((b->data[n / 8] & mask) == 0){
			b->data[n / 8] = b->data[n / 8] | mask;
			bwrite(b);
			brelse(b);
			z = bread(n);
			memset(z->data, 0, BSIZE);
			bwrite(z);
			brelse(z);
			return n;
		}
	}
	panic("balloc: out of blocks");
	return 0;
}

void
bfree(uint n)
{
	struct buf *b;

	b = bread(sb.bmapstart);
	b->data[n / 8] = b->data[n / 8] & ~(1 << (n % 8));
	bwrite(b);
	brelse(b);
}

// ---------------------------------------------------------------- inodes

struct inode*
iget(uint inum)
{
	struct inode *ip, *empty;

	acquire(&icache_lock);
	empty = 0;
	for(ip = inodes; ip < &inodes[NINODE]; ip++){
		if(ip->ref > 0 && ip->inum == inum){
			ip->ref++;
			release(&icache_lock);
			return ip;
		}
		if(empty == 0 && ip->ref == 0)
			empty = ip;
	}
	if(empty == 0)
		panic("iget: no inodes");
	empty->inum = inum;
	empty->ref = 1;
	empty->valid = 0;
	empty->busy = 0;
	empty->gone = 0;
	release(&icache_lock);
	return empty;
}

struct inode*
idup(struct inode *ip)
{
	acquire(&icache_lock);
	ip->ref++;
	release(&icache_lock);
	return ip;
}

uint
iblock(uint inum)
{
	return sb.inodestart + inum / (BSIZE / 64);
}

void
ilock(struct inode *ip)
{
	struct buf *b;
	struct dinode *d;

	acquire(&icache_lock);
	while(ip->busy)
		sleep(ip, &icache_lock);
	ip->busy = 1;
	release(&icache_lock);
	if(!ip->valid){
		b = bread(iblock(ip->inum));
		d = (struct dinode*)b->data + ip->inum % (BSIZE / 64);
		ip->type = d->type;
		ip->major = d->major;
		ip->size = d->size;
		memmove((char*)ip->addrs, (char*)d->addrs, sizeof ip->addrs);
		brelse(b);
		ip->valid = 1;
		if(ip->type == 0)
			panic("ilock: a free inode");
	}
}

void
iunlock(struct inode *ip)
{
	acquire(&icache_lock);
	ip->busy = 0;
	wakeup(ip);
	release(&icache_lock);
}

// the inode's fields to the disk
void
iupdate(struct inode *ip)
{
	struct buf *b;
	struct dinode *d;

	b = bread(iblock(ip->inum));
	d = (struct dinode*)b->data + ip->inum % (BSIZE / 64);
	d->type = ip->type;
	d->major = ip->major;
	d->size = ip->size;
	memmove((char*)d->addrs, (char*)ip->addrs, sizeof ip->addrs);
	bwrite(b);
	brelse(b);
}

// a free inode on the disk, of a type
struct inode*
ialloc(int type)
{
	uint inum;
	struct buf *b;
	struct dinode *d;

	for(inum = 1; inum < sb.ninodes; inum++){
		b = bread(iblock(inum));
		d = (struct dinode*)b->data + inum % (BSIZE / 64);
		if(d->type == 0){
			memset(d, 0, sizeof *d);
			d->type = type;
			bwrite(b);
			brelse(b);
			return iget(inum);
		}
		brelse(b);
	}
	panic("ialloc: no inodes");
	return 0;
}

// the file's blocks freed, its size 0 (ip locked)
void
itrunc(struct inode *ip)
{
	int i;
	struct buf *b;
	uint *a;

	for(i = 0; i < NDIRECT; i++)
		if(ip->addrs[i]){
			bfree(ip->addrs[i]);
			ip->addrs[i] = 0;
		}
	if(ip->addrs[NDIRECT]){
		b = bread(ip->addrs[NDIRECT]);
		a = (uint*)b->data;
		for(i = 0; i < NINDIRECT; i++)
			if(a[i])
				bfree(a[i]);
		brelse(b);
		bfree(ip->addrs[NDIRECT]);
		ip->addrs[NDIRECT] = 0;
	}
	ip->size = 0;
	iupdate(ip);
}

// a pointer dropped; the last, of an unlinked file, frees it
void
iput(struct inode *ip)
{
	acquire(&icache_lock);
	if(ip->ref == 1 && ip->valid && ip->gone){
		ip->busy = 1;
		release(&icache_lock);
		itrunc(ip);
		ip->type = 0;
		iupdate(ip);
		ip->valid = 0;
		acquire(&icache_lock);
		ip->busy = 0;
	}
	ip->ref--;
	release(&icache_lock);
}

void
iunlockput(struct inode *ip)
{
	iunlock(ip);
	iput(ip);
}

// the disk block of the file's n-th, allocated if need be
uint
bmap(struct inode *ip, uint n)
{
	struct buf *b;
	uint *a, addr;

	if(n < NDIRECT){
		if(ip->addrs[n] == 0)
			ip->addrs[n] = balloc();
		return ip->addrs[n];
	}
	n -= NDIRECT;
	if(n >= NINDIRECT)
		panic("bmap: too large");
	if(ip->addrs[NDIRECT] == 0)
		ip->addrs[NDIRECT] = balloc();
	b = bread(ip->addrs[NDIRECT]);
	a = (uint*)b->data;
	if((addr = a[n]) == 0){
		addr = a[n] = balloc();
		bwrite(b);
	}
	brelse(b);
	return addr;
}

void
stati(struct inode *ip, struct stat *st)
{
	st->type = ip->type;
	st->ino = ip->inum;
	st->size = ip->size;
}

// a process's memory (user) or the kernel's, as a copy's other end
int
either_copyout(int user, uint dst, char *src, uint n)
{
	if(user)
		return copyout(myproc()->pagetable, dst, src, n);
	memmove((char*)dst, src, n);
	return 0;
}

int
either_copyin(char *dst, int user, uint src, uint n)
{
	if(user)
		return copyin(myproc()->pagetable, dst, src, n);
	memmove(dst, (char*)src, n);
	return 0;
}

// n bytes at off, to dst; the count read (ip locked)
int
readi(struct inode *ip, int user, uint dst, uint off, uint n)
{
	uint tot, m;
	struct buf *b;

	if(off > ip->size)
		return 0;
	if(off + n > ip->size)
		n = ip->size - off;
	for(tot = 0; tot < n; tot += m, off += m, dst += m){
		b = bread(bmap(ip, off / BSIZE));
		m = BSIZE - off % BSIZE;
		if(m > n - tot)
			m = n - tot;
		if(either_copyout(user, dst, (char*)b->data + off % BSIZE, m) < 0){
			brelse(b);
			return -1;
		}
		brelse(b);
	}
	return n;
}

int
writei(struct inode *ip, int user, uint src, uint off, uint n)
{
	uint tot, m;
	struct buf *b;

	if(off > ip->size || off + n > (NDIRECT + NINDIRECT) * BSIZE)
		return -1;
	for(tot = 0; tot < n; tot += m, off += m, src += m){
		b = bread(bmap(ip, off / BSIZE));
		m = BSIZE - off % BSIZE;
		if(m > n - tot)
			m = n - tot;
		if(either_copyin((char*)b->data + off % BSIZE, user, src, m) < 0){
			brelse(b);
			break;
		}
		bwrite(b);
		brelse(b);
	}
	if(off > ip->size)
		ip->size = off;
	iupdate(ip);
	return tot;
}

// ---------------------------------------------------------------- directories and paths

// the entry named name in dp, its offset in *poff (dp locked)
struct inode*
dirlookup(struct inode *dp, char *name, uint *poff)
{
	uint off;
	struct dirent de;

	if(dp->type != T_DIR)
		panic("dirlookup");
	for(off = 0; off < dp->size; off += sizeof de){
		readi(dp, 0, (uint)&de, off, sizeof de);
		if(de.inum != 0 && strncmp(name, de.name, DIRSIZ) == 0){
			if(poff)
				*poff = off;
			return iget(de.inum);
		}
	}
	return 0;
}

// a new entry in dp (locked), in a free slot or at the end
int
dirlink(struct inode *dp, char *name, uint inum)
{
	uint off;
	struct dirent de;
	struct inode *ip;

	if((ip = dirlookup(dp, name, 0)) != 0){
		iput(ip);
		return -1;
	}
	for(off = 0; off < dp->size; off += sizeof de){
		readi(dp, 0, (uint)&de, off, sizeof de);
		if(de.inum == 0)
			break;
	}
	memset(&de, 0, sizeof de);
	de.inum = inum;
	memmove(de.name, name, strlen(name) < DIRSIZ ? strlen(name) : DIRSIZ);
	if(writei(dp, 0, (uint)&de, off, sizeof de) != sizeof de)
		return -1;
	return 0;
}

// the path's next element into name (DIRSIZ at most), what follows it
char*
skipelem(char *path, char *name)
{
	char *s;
	int len;

	while(*path == '/')
		path++;
	if(*path == 0)
		return 0;
	s = path;
	while(*path != '/' && *path != 0)
		path++;
	len = path - s;
	if(len > DIRSIZ)
		len = DIRSIZ;
	memmove(name, s, len);
	if(len < DIRSIZ)
		name[len] = 0;
	while(*path == '/')
		path++;
	return path;
}

// the path's inode, or its parent's (the last element in name)
struct inode*
namex(char *path, int parent, char *name)
{
	struct inode *ip, *next;

	if(*path == '/')
		ip = iget(ROOTINO);
	else
		ip = idup(myproc()->cwd);
	while((path = skipelem(path, name)) != 0){
		ilock(ip);
		if(ip->type != T_DIR){
			iunlockput(ip);
			return 0;
		}
		if(parent && *path == 0){
			iunlock(ip);
			return ip;
		}
		if((next = dirlookup(ip, name, 0)) == 0){
			iunlockput(ip);
			return 0;
		}
		iunlockput(ip);
		ip = next;
	}
	if(parent){
		iput(ip);
		return 0;
	}
	return ip;
}

struct inode*
namei(char *path)
{
	char name[DIRSIZ + 1];

	return namex(path, 0, name);
}

struct inode*
nameiparent(char *path, char *name)
{
	return namex(path, 1, name);
}

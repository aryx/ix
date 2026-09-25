// Claude Code, Copyright (C) 2026 Yoann Padioleau, LGPL (see TinyC.ml)
//
// tiny-os v6: the pages (xv6's vm.c; the ideas: main.c). Sv32: a root
// of 1,024 entries, each a table of 1,024 pages of 4 KB. The kernel is
// in every page table:
// [0, KERNTOP) identity-mapped by the root's first two entries, and the
// devices' page by its last, the same three entries (the same two
// tables) in every process's root; a process's own pages are the
// entries of [USERBASE, USERTOP), its program from USERBASE up, its
// stack the last page. So a trap changes no page table, and the kernel
// reads a process's memory by its physical pages, identity-mapped.
#include "defs.h"

pagetable_t kernel_pagetable;

// the address of the entry for va, its table made if alloc
uint*
walk(pagetable_t pt, uint va, int alloc)
{
	uint *e;
	pagetable_t t;

	e = &pt[va >> 22];
	if(*e & PTE_V)
		t = (pagetable_t)((*e >> 10) << 12);
	else {
		if(!alloc || (t = kalloc()) == 0)
			return 0;
		memset(t, 0, PGSIZE);
		*e = (((uint)t >> 12) << 10) | PTE_V;
	}
	return &t[(va >> 12) & 1023];
}

int
mappages(pagetable_t pt, uint va, uint size, uint pa, int perm)
{
	uint a, last;
	uint *e;

	a = pgrounddown(va);
	last = pgrounddown(va + size - 1);
	for(;;){
		if((e = walk(pt, a, 1)) == 0)
			return -1;
		if(*e & PTE_V)
			panic("mappages: remap");
		*e = ((pa >> 12) << 10) | perm | PTE_V;
		if(a == last)
			break;
		a += PGSIZE;
		pa += PGSIZE;
	}
	return 0;
}

void
kvminit(void)
{
	kernel_pagetable = kalloc();
	memset(kernel_pagetable, 0, PGSIZE);
	mappages(kernel_pagetable, 0, KERNTOP, 0, PTE_R | PTE_W | PTE_X);
	mappages(kernel_pagetable, DEVPAGE, PGSIZE, DEVPHYS, PTE_R | PTE_W);
	w_satp(SATP_ON | ((uint)kernel_pagetable >> 12));
}

// a user page's physical address, 0 if va is not one
uint
walkaddr(pagetable_t pt, uint va)
{
	uint *e;

	if(va < USERBASE || va >= USERTOP)
		return 0;
	e = walk(pt, va, 0);
	if(e == 0 || (*e & PTE_V) == 0 || (*e & PTE_U) == 0)
		return 0;
	return (*e >> 10) << 12;
}

// a process's page table: the kernel's three entries, and its stack
pagetable_t
uvmcreate(void)
{
	pagetable_t pt;
	char *stack;

	if((pt = kalloc()) == 0)
		return 0;
	memset(pt, 0, PGSIZE);
	pt[0] = kernel_pagetable[0];
	pt[1] = kernel_pagetable[1];
	pt[1023] = kernel_pagetable[1023];
	if((stack = kalloc()) == 0){
		kfree(pt);
		return 0;
	}
	memset(stack, 0, PGSIZE);
	mappages(pt, USERTOP - PGSIZE, PGSIZE, (uint)stack, PTE_R | PTE_W | PTE_U);
	return pt;
}

// the pages of [USERBASE + from, USERBASE + to) unmapped, and freed
void
uvmunmap(pagetable_t pt, uint from, uint to)
{
	uint a;
	uint *e;

	for(a = pgroundup(USERBASE + from); a < pgroundup(USERBASE + to); a += PGSIZE){
		if((e = walk(pt, a, 0)) == 0 || (*e & PTE_V) == 0)
			panic("uvmunmap");
		kfree((void*)((*e >> 10) << 12));
		*e = 0;
	}
}

// the program's memory grown from oldsz to newsz, its new pages zero;
// newsz, or 0 if out of memory
uint
uvmalloc(pagetable_t pt, uint oldsz, uint newsz)
{
	uint a;
	char *mem;

	if(USERBASE + newsz > USERTOP - PGSIZE)
		return 0;
	for(a = pgroundup(USERBASE + oldsz); a < USERBASE + newsz; a += PGSIZE){
		if((mem = kalloc()) == 0){
			uvmunmap(pt, oldsz, a - USERBASE);
			return 0;
		}
		memset(mem, 0, PGSIZE);
		if(mappages(pt, a, PGSIZE, (uint)mem, PTE_R | PTE_W | PTE_X | PTE_U) < 0){
			kfree(mem);
			uvmunmap(pt, oldsz, a - USERBASE);
			return 0;
		}
	}
	return newsz;
}

// the whole table freed: the program's pages, the stack, the user's
// tables (not the kernel's, shared), the root
void
uvmfree(pagetable_t pt, uint sz)
{
	int i;

	uvmunmap(pt, 0, sz);
	uvmunmap(pt, USERTOP - PGSIZE - USERBASE, USERTOP - USERBASE);
	for(i = 2; i < 1023; i++)
		if(pt[i] & PTE_V)
			kfree((void*)((pt[i] >> 10) << 12));
	kfree(pt);
}

// a page copied into new, at va
int
uvmcopy1(pagetable_t old, pagetable_t new, uint va)
{
	char *mem;

	if((mem = kalloc()) == 0)
		return -1;
	memmove(mem, (char*)walkaddr(old, va), PGSIZE);
	if(mappages(new, va, PGSIZE, (uint)mem, PTE_R | PTE_W | PTE_X | PTE_U) < 0){
		kfree(mem);
		return -1;
	}
	return 0;
}

// the program's memory and its stack copied into new (fork's), whose
// stack page uvmcreate made
int
uvmcopy(pagetable_t old, pagetable_t new, uint sz)
{
	uint a;

	for(a = USERBASE; a < USERBASE + sz; a += PGSIZE)
		if(uvmcopy1(old, new, a) < 0){
			uvmunmap(new, 0, a - USERBASE);
			return -1;
		}
	memmove((char*)walkaddr(new, USERTOP - PGSIZE), (char*)walkaddr(old, USERTOP - PGSIZE), PGSIZE);
	return 0;
}

// the kernel and a process's memory: page by page, through the pages'
// physical addresses (the kernel's are identity-mapped)
int
copyout(pagetable_t pt, uint dstva, char *src, uint len)
{
	uint n, pa, va0;

	while(len > 0){
		va0 = pgrounddown(dstva);
		if((pa = walkaddr(pt, va0)) == 0)
			return -1;
		n = PGSIZE - (dstva - va0);
		if(n > len)
			n = len;
		memmove((char*)(pa + (dstva - va0)), src, n);
		len -= n;
		src += n;
		dstva = va0 + PGSIZE;
	}
	return 0;
}

int
copyin(pagetable_t pt, char *dst, uint srcva, uint len)
{
	uint n, pa, va0;

	while(len > 0){
		va0 = pgrounddown(srcva);
		if((pa = walkaddr(pt, va0)) == 0)
			return -1;
		n = PGSIZE - (srcva - va0);
		if(n > len)
			n = len;
		memmove(dst, (char*)(pa + (srcva - va0)), n);
		len -= n;
		dst += n;
		srcva = va0 + PGSIZE;
	}
	return 0;
}

// a string of at most max bytes, its zero included; 0, or -1
int
copyinstr(pagetable_t pt, char *dst, uint srcva, uint max)
{
	uint pa;

	for(; max > 0; max--, dst++, srcva++){
		if((pa = walkaddr(pt, pgrounddown(srcva))) == 0)
			return -1;
		*dst = *(char*)(pa + (srcva & (PGSIZE - 1)));
		if(*dst == 0)
			return 0;
	}
	return -1;
}

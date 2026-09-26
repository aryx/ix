(* mini-xv6's memory (xv6's kalloc.c and vm.c): the physical pages, and
 * a process's address space: its bytes [0, sz) through its own
 * translation table (TTBR0), a radix tree whose levels and entries are
 * the board's (Arch: the Pi1's two levels of ARMv6 descriptors, the
 * Pi4's three of ARMv8's). Pages are records (Page.t); only Arch
 * knows the bits. *)

val pgsize : int
val pgroundup : int -> int

(* the free physical pages: a zeroed one, or None; one given back; how
 * many *)
val kalloc : unit -> int option
val kfree : int -> unit
val nfree : unit -> int

(* A space is its first-level table's physical address (a pgdir). *)

(* a new one, empty; or None *)
val create : unit -> int option

(* claude: whether a page is mapped at [va] (mini-9pi's page faults);
 * the page there *)
val mapped : int -> int -> bool
val lookup : int -> int -> Page.t option

(* claude: mini-9pi's, whose pages belong to its segments (shared by
 * processes): [map pgdir va pa] a page mapped there (the user's, to
 * write; false: no page for a table), [unmap pgdir va] one unmapped but
 * not freed, [free_tables pgdir] a space's tables freed, not its pages *)
val map : int -> int -> int -> bool
val unmap : int -> int -> unit
val free_tables : int -> unit

(* [alloc pgdir oldsz newsz]: [oldsz, newsz) given fresh zeroed pages
 * (uvmalloc): the new size, or None (past the user's addresses, or no
 * page left: what it added freed) *)
val alloc : int -> int -> int -> int option

(* [dealloc pgdir oldsz newsz]: the pages from newsz up freed
 * (deallocuvm): the new size *)
val dealloc : int -> int -> int -> int

(* the page at [va] made the kernel's: exec's guard page (clearpteu) *)
val guard : int -> int -> unit

(* every page and table of a space, then the space (freevm) *)
val free : int -> unit

(* [copy pgdir sz]: [0, sz) copied into a new space (copyuvm), or None *)
val copy : int -> int -> int option

(* [copy_range pgdir dst lo hi]: the pages of [lo, hi) mapped in pgdir
 * copied into the space dst (false: no page left, dst to be freed) *)
val copy_range : int -> int -> int -> int -> bool

(* a process's bytes, through its table (xv6-riscv's copyin, copyout,
 * copyinstr: the user's pages only, the guard page refused).
 * [read_prefix]: the bytes before the first page out of reach, [n] at
 * most; [read]: all [n] or None; [room]: how many of [n] the user can
 * write; [copyout]: all of [s] (true), or up to the first page out of
 * reach; [read_string]: a string, its NUL within [max] bytes; [write]:
 * any page mapped (exec loading a program) *)
val read_prefix : int -> int -> int -> string
val read : int -> int -> int -> string option
val room : int -> int -> int -> int
val copyout : int -> int -> string -> bool
val read_string : int -> int -> int -> string option
val write : int -> int -> string -> bool

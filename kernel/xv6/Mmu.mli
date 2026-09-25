(* mini-xv6's memory (xv6's kalloc.c and vm.c): the physical pages, and
 * a process's address space, xv6 arm-pi1's: its bytes [0, sz) below 1GB,
 * through its own first-level table (TTBR0, TTBCR N = 2: 1024 entries,
 * a page), coarse tables of 256 small pages (kernel/step4).
 *
 * Page table entries are records (Types.l1, l2); only [encode] and
 * [decode] know the bits. *)

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

(* [alloc pgdir oldsz newsz]: [oldsz, newsz) given fresh zeroed pages
 * (allocuvm): the new size, or None (1GB reached, or no page left:
 * what it added freed) *)
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

(* a process's bytes, through its table. [read] and [write] reach any
 * page mapped (xv6's kernel checks the bounds against sz only, the
 * guard page within); [copyout] only the user's pages (exec's). None
 * or false: a page not mapped *)
val read : int -> int -> int -> string option
val write : int -> int -> string -> bool
val copyout : int -> int -> string -> bool

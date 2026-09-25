(* A page of a process's: its physical address, who may use it (the
 * guard page below a stack: the kernel only). Each board's Arch encodes
 * it in its page table entries; Mmu makes and walks the tables. *)

type perm = Kernel_rw | User_ro | User_rw

type t = { pa : int; perm : perm }

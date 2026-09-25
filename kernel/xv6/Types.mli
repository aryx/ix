(* mini-xv6's data (plan_kernel.md): the types every module shares, as
 * xv6's headers (proc.h, file.h, fs.h, mmu.h) are, but as OCaml says
 * them. A process's state carries what matters in it (what it sleeps
 * on); a file is a pipe's end, an inode, or a device, not a tag and
 * three pointers; what a process waits for is a channel, a variant
 * compared by what it names (xv6's is any address). *)

(*****************************************************************************)
(* Memory *)
(*****************************************************************************)

(* ARMv6's short descriptors, the kinds the kernel uses (Mmu.ml) *)
type perm = Kernel_rw | User_ro | User_rw

type page = { pa : int; perm : perm }

type l1 = L1_fault | Coarse of int          (* a second-level table's physical address *)
type l2 = L2_fault | Page of page

(*****************************************************************************)
(* Files *)
(*****************************************************************************)

(* an inode's type, on the disk a short (fs.h's T_DIR 1, T_FILE 2,
 * T_DEVICE 3; 0 a free inode) *)
type itype = Free | Dir | File | Devnode

(* an inode in use: its number and how many hold it; the rest (type,
 * size, block addresses) stays on the disk, read and written there
 * (Fs.ml: the disk is RAM) *)
type inode = { inum : int; mutable iref : int }

(* a pipe's buffer: 512 bytes, nread and nwrite counting forever (xv6's) *)
type pipe = {
  pdata : Bytes.t;
  mutable nread : int;
  mutable nwrite : int;
  mutable readopen : bool;
  mutable writeopen : bool;
}

type file_kind = Pipe_end of pipe | Inode_file of inode | Device of inode * int (* its major *)

type file = {
  kind : file_kind;
  mutable fref : int;
  readable : bool;
  writable : bool;
  mutable off : int;
}

(*****************************************************************************)
(* Processes *)
(*****************************************************************************)

(* what a sleeping process waits for *)
type chan =
  | Ticks                   (* sleep(n), a tick *)
  | Child_of of int         (* wait: a child of this pid exiting *)
  | Pipe_readable of pipe
  | Pipe_writable of pipe
  | Console_input

type state = Runnable | Running | Sleeping of chan | Zombie

type proc = {
  pid : int;
  slot : int;                   (* its kernel stack and trap frame (machine.c) *)
  mutable state : state;
  mutable pgdir : int;          (* its first-level table's physical address *)
  mutable sz : int;             (* its memory: [0, sz) *)
  mutable parent : int;         (* a pid; 0 for init *)
  mutable killed : bool;
  ofile : file option array;    (* NOFILE *)
  mutable cwd : inode;
  mutable name : string;
}

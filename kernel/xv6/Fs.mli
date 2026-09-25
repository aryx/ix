(* mini-xv6's file system (xv6's fs.c, and sysfile.c's operations on
 * names): xv6 arm-pi1's on-disk format, read and written in place.
 *
 * The disk is RAM (xv6 arm-pi1's memide.c: fs.img linked into the
 * kernel, start.s), so the layers xv6 puts between a system call and a
 * disk block have nothing to do here, and are not:
 * - no buffer cache (bio.c): a block is its address, base + b * 512;
 * - no log (log.c): a write cannot be half done by a crash of the disk,
 *   the whole disk is lost with the machine; filewrite's chunking for
 *   the log goes too (File.ml);
 * - no inode copies (ilock's I_VALID, iupdate): an inode's fields are
 *   read and written on the disk, through [get] and [set];
 * - no locks: one core, a kernel never interrupted (Proc.ml).
 * What stays in memory is what the disk cannot say: which inodes are in
 * use, and by how many ([Types.inode], the table [icache]). *)

val rootino : int

(* An inode's fields are on the disk, reached by [get] and [set]: *)
type field
val i_major : field
val i_nlink : field
val i_size : field
val get : Types.inode -> field -> int
val set : Types.inode -> field -> int -> unit

(* its type, the short at the dinode's start *)
val itype : Types.inode -> Types.itype

(* the inodes in use (xv6's icache, NINODE at most): one held, once
 * more, let go (the last reference to an inode no directory names
 * frees it) *)
val iget : int -> Types.inode
val idup : Types.inode -> Types.inode
val iput : Types.inode -> unit

(* the file's blocks freed, its size 0 (O_TRUNC) *)
val itrunc : Types.inode -> unit

(* [readi ip off n]: n bytes, fewer at the end, None when [off] is past
 * it. [writei ip off s]: s's length, the file grown; or -1 (off past
 * the end, or past MAXFILE). Files and directories; devices are
 * File.ml's *)
val readi : Types.inode -> int -> int -> string option
val writei : Types.inode -> int -> string -> int

(* struct stat's bytes, at 0 and at 16 (its padding the user's) *)
val stat_head : Types.inode -> string
val stat_size : Types.inode -> string

(* a path's inode, from the root or the running process's directory:
 * held; or its directory's and its last element (at most 14 bytes:
 * DIRSIZ) *)
val namei : string -> Types.inode option
val nameiparent : string -> (Types.inode * string) option

(* sysfile.c's: [create path t major minor], the inode (held) made or,
 * for a file, found; [link old new]; [unlink path] (not "." nor "..",
 * not a directory with entries). 0 or -1 *)
val create : string -> Types.itype -> int -> int -> Types.inode option
val link : string -> string -> int
val unlink : string -> int

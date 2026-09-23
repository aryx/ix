#!args NPROC=2 all
# $nproc: the slot running a job
all:V: a b
	echo all
a:V:
	sleep 0.2; echo a slot=$nproc
b:V:
	echo b slot=$nproc

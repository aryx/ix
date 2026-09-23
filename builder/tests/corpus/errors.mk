#!args ok
#!args bad
#!args -k all
#!args deleted
#!args noerr
# a failing recipe: stop, or with -k go on with the rest; :D: deletes
all:V: bad good
	echo all
good:V:
	echo good
bad:V:
	echo bad; false
	echo not reached
ok:VQ:
	echo quiet recipe
deleted:D:
	echo half > deleted; false
noerr:VE:
	false
	echo went on

#!args -n
# the first rule without % or & is the default
%.o:V:
	echo meta
first second:V:
	echo making $target
third:V:
	echo third

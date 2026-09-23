#!args -n
# backslash-newline in a header; recipes keep theirs
all:V: a \
  b
	echo one \
	  two
a b:V:
	echo $target # a comment

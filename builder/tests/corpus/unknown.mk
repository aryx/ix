#!args -n nothere
#!args -n norecipe
#!args -n -k all
# don't know how to make; no recipe to make
all:V: nothere other
	echo all
other:V:
	echo other
norecipe: dep
dep:V:
	echo dep

#!args
# an empty variable under rc: 9base exports E= and rc sees one empty
# word; mini-mk, like omk and like Plan 9's empty /env file, sees ()
MKSHELL=rc
E=
F=a b
t:V:
	echo count $#E $#F

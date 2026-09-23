#!setup printf 'inc:V:\n\techo inc shell=$0\n' > inc.mk
#!args top list
# MKSHELL in a mkfile, and an include's private copy
MKSHELL=rc
<inc.mk
top:V: inc
	echo top shell $0; x=(a b); echo $#x
X=a b
list:V:
	echo $#X

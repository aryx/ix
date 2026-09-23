#!setup printf 'INC=from include\ninc:V:\n\techo inc shell=$0 INC=$INC\n' > inc.mk; printf 'echo PIPED=yes\n' > gen.sh
#!args -n all
#!args all
# <file, a missing include, <|cmd, backquotes
<inc.mk
<missing.mk
<|sh gen.sh
B=`echo back quoted`
C=`{echo rc style}
all:V: inc
	echo INC=$INC PIPED=$PIPED B=$B C=$C

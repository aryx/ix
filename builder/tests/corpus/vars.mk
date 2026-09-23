#!args -n all
#!args -n late
#!args -n subst
#!args -n undef
#!args -n CC=z x y
# lists glue at their ends; rule headers expand when read
X=a b
all:V: $X.o pre$X $X$X
	echo all from $prereq
%:V:
	echo making $target
Y=early
late:V: $Y
Y=changed
SRC=Ast.ml Main.ml lexer.mll
subst:V: ${SRC:%.ml=%.cmo} ${SRC:%.mll=gen/%.ml} ${SRC:Main%=M%}
	echo subst $prereq
undef:V: ${UNDEF:%.c=%.o} x${UNDEF}y
	echo undef $prereq
CC=a
x:V: $CC
CC=b
y:V: $CC

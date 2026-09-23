#!args -n q
#!args q
# sh quoting in rule headers; recipes printed with quotes left alone
X=a b
q:V: "x y" 'p q' a\ b
	echo q prereq=$prereq '$X' "$target" $X ${X} $HOME
"x y" 'p q' 'a b':V:
	echo made $target

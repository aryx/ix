#include "libc.h"

int
fib(int n)
{
	return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

char*
name(int n)
{
	switch(n){
	case 0:
		return "zero";
	case 1:
	case 2:
		return "small";
	case 100:
		return "hundred";
	default:
		return "other";
	}
}

void
main(int argc, char *argv[])
{
	int i, j, n, k;

	for(i = 0; i < 12; i++)
		print("%d ", fib(i));
	print("\n");
	n = 0;
	for(i = 0; i < 10; i++){
		if(i == 3)
			continue;
		if(i == 8)
			break;
		n += i;
	}
	print("%d\n", n);
	i = 0;
	do
		i += 3;
	while(i < 10);
	print("%d\n", i);
	for(i = -1; i < 4; i++)
		print("%s ", name(i == 3 ? 100 : i));
	print("\n");
	k = 0;
	for(i = 0; i < 6; i++)
		switch(i % 3){
		case 0:
			k += 1;
		case 1:
			k += 10;
			break;
		default:
			k += 100;
		}
	print("%d\n", k);
	i = 0; j = 5;
	if(i && j / i)
		print("no\n");
	if(!i || j / i)
		print("yes\n");
	n = (i = 4, j = i * 2, i + j);
	print("%d %d %d\n", n, i < j && j < 10, i > j || j == 8);
	while(1){
		if(++i > 20)
			break;
	}
	print("%d\n", i);
	exits(0);
}

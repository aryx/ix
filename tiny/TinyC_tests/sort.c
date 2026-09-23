#include "libc.h"

/* a real program: quicksort, then an RPN calculator on the arguments */

void
swap(int *a, int *b)
{
	int t;

	t = *a;
	*a = *b;
	*b = t;
}

void
qsort1(int *a, int n)
{
	int i, last;

	if(n < 2)
		return;
	swap(&a[0], &a[n / 2]);
	last = 0;
	for(i = 1; i < n; i++)
		if(a[i] < a[0])
			swap(&a[++last], &a[i]);
	swap(&a[0], &a[last]);
	qsort1(a, last);
	qsort1(a + last + 1, n - last - 1);
}

int stack[16];
int sp;

int
rpn(char *s)
{
	int n;

	sp = 0;
	while(*s){
		if(*s >= '0' && *s <= '9'){
			n = 0;
			while(*s >= '0' && *s <= '9')
				n = n * 10 + *s++ - '0';
			stack[sp++] = n;
			continue;
		}
		switch(*s){
		case '+': sp--; stack[sp - 1] += stack[sp]; break;
		case '-': sp--; stack[sp - 1] -= stack[sp]; break;
		case '*': sp--; stack[sp - 1] *= stack[sp]; break;
		case '/': sp--; stack[sp - 1] /= stack[sp]; break;
		}
		s++;
	}
	return stack[0];
}

void
main(int argc, char *argv[])
{
	int a[20], i, seed;

	seed = 12345;
	for(i = 0; i < 20; i++){
		seed = seed * 1103515245 + 12345;
		a[i] = (seed >> 16) & 1023;
	}
	qsort1(a, 20);
	for(i = 0; i < 20; i++)
		print("%d ", a[i]);
	print("\n");
	print("%d %d\n", rpn("3 4 + 2 *"), rpn("100 7 / 3 - 5 5 * +"));
	exits(0);
}

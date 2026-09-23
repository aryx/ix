#include "libc.h"

int a[10];
char buf[64];

int
sum(int *p, int n)
{
	int s;

	s = 0;
	while(n-- > 0)
		s += *p++;
	return s;
}

void
rev(char *s)
{
	char *e, t;

	e = s + strlen(s) - 1;
	while(s < e){
		t = *s;
		*s++ = *e;
		*e-- = t;
	}
}

void
main(int argc, char *argv[])
{
	int i, m[3][4], *p, **pp;

	for(i = 0; i < 10; i++)
		a[i] = i * i;
	print("%d\n", sum(a, 10));
	print("%d %d\n", sum(a + 5, 3), (int)(&a[7] - &a[2]));
	for(i = 0; i < 12; i++)
		m[i / 4][i % 4] = i;
	print("%d %d\n", m[2][1], *(*(m + 1) + 3));
	p = &a[3];
	pp = &p;
	**pp = 100;
	print("%d %d\n", a[3], p[1]);
	strcpy(buf, "hello, world");
	rev(buf);
	print("%s %d\n", buf, strlen(buf));
	for(i = 0; i < argc; i++)
		print("%s|", argv[i] + 2);
	print("\n");
	p = 0;
	print("%d\n", p == 0);
	exits(0);
}

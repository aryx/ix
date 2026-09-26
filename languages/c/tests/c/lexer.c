#define ADD(a, b) ((a) + /* c */ (b)) // x
#define STR(x) "x is \"" x
#define LONG 1 + \
	2
#define CH(c) (c == ',' ? 1 : 2)
#define V(fmt, ...) f(fmt, __VA_ARGS__)
int f(char*, ...);
char *s = "a\tb\n\\\"\x41\101\0z";
int w[] = { L'x', L'\u', 'a', '\'', '\n', 0x1F, 0777, 07, 0, 10u, 4000000000, 077777777777, 0xffffffffffLL };
unsigned int *ls = L"héllo";
double d[] = { 1.5, .25, 1e3, 2.5e-3f, 3.L, 1E+2 };
int g(int a) { return ADD(a, 3) + LONG + CH(',') + V("%d", a, a) + sizeof STR("q"); }
#ifdef LONG
int y = 1;
#else
int y = 2;
#endif
#ifndef NOPE
int z = 3;
#endif

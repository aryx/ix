struct P { int x, y; };
struct R { struct P a, b; char name[8]; int n; };
struct R r1 = { { 1, 2 }, { 3, 4 }, "abc", 5 };
struct R r2 = { 1, 2, 3, 4, "defghij", 6 };
struct R r3 = { .n = 9, .a = { 7, 8 } };
int arr[10] = { 1, 2, [5] = 6, 7 };
int arr2[] = { 1, 2, 3 };
char s1[] = "hello";
char s2[5] = "hello";
char s3[10] = "hi";
char *ps[] = { "one", "two", 0 };
unsigned int wide[] = L"wide";
struct P parr[] = { 1, 2, 3, 4, { 5, 6 } };
double dd[3] = { 1.5, 2 };
int *ip = &arr[3];
struct P gp = { 1 };
void f(void) {
	int a[20] = { 1, 2 };
	int b[4] = { 1, 2, 3, 4 };
	char c[16] = "local";
	struct P p = { 1, 2 };
	struct P q = p;
	struct R big = { { 1, 2 } };
	static int st[3] = { 4, 5, 6 };
	int x = 3, y = x + 1;
	USED(a); USED(b); USED(c); USED(q); USED(big); USED(st); USED(y);
}

typedef long long vlong; typedef unsigned long long uvlong;
vlong g; uvlong ug; int i; char c; unsigned short us; double d; float fl; void *vp;
vlong f(vlong a, vlong b) {
	vlong x = a + b, y = a * b - a / b % 3;
	x += y; x -= 1; x *= 3; x /= b; x %= 7; x <<= 2; x >>= 1; x &= 0xff; x |= 4; x ^= y;
	x++; ++x; x--; --x;
	if (x < y || x == 0 && !y) x = -x;
	x = ~x;
	i = x; c = x; us = x; d = x; fl = x; vp = (void*)x;
	x = i; x = c; x = us; x = d; ug = g >> 3; ug = ug >> 2; ug = ug / 3;
	x = x ? y : a;
	return x > 0 ? x : g;
}
int t(vlong v) { return v != 0 && g; }

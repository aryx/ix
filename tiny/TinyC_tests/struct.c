#include "libc.h"

typedef struct Node Node;
struct Node {
	int val;
	char tag;
	Node *next;
};

struct Point {
	short x;
	long long y;
	char name[5];
};

struct Point pts[3];

Node*
push(Node *l, int v)
{
	Node *n;

	n = malloc(sizeof(Node));
	n->val = v;
	n->tag = 'a' + v;
	n->next = l;
	return n;
}

void
main(int argc, char *argv[])
{
	Node *l, *n;
	int i, s;
	struct Point p, *q;

	l = 0;
	for(i = 0; i < 5; i++)
		l = push(l, i);
	s = 0;
	for(n = l; n; n = n->next){
		s = s * 10 + n->val;
		print("%c", n->tag);
	}
	print(" %d\n", s);
	p.x = -3;
	p.y = 1LL << 35;
	strcpy(p.name, "abcd");
	q = &p;
	print("%d %lld %s %d\n", q->x, q->y, q->name, sizeof(struct Point));
	for(i = 0; i < 3; i++){
		pts[i].x = i;
		pts[i].y = i * 1000;
	}
	print("%d %lld %d\n", pts[2].x, pts[1].y, sizeof(Node));
	exits(0);
}

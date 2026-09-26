/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* What runtime.c uses of Plan 9's libc, from POSIX's: for gcc, when
 * mini-ml's code goes through GNU's as and ld (Gas.ml, decision 8's
 * route B), in user programs (tests/gas.sh). */

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdint.h>

typedef unsigned char uchar;
typedef long long vlong;
typedef unsigned long long uvlong;
typedef intptr_t intptr;
typedef uintptr_t uintptr;

#define nil NULL
#define snprint snprintf

static int
create(char *name, int mode, int perm)
{
	(void)mode;
	return open(name, O_WRONLY | O_CREAT | O_TRUNC, perm);
}

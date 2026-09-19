/* SPDX-License-Identifier: ISC */
#ifndef _STDBOOL_H
#define _STDBOOL_H

/* bool is _Bool, not int: a structure holding one has to have the layout
 * every other compiler gives it. */
#define bool  _Bool
#define true  1
#define false 0
#define __bool_true_false_are_defined 1

#endif

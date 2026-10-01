/* SPDX-License-Identifier: ISC */
#include <stdio.h>

double ldret(void), ldarg(void), ldsum(void);
void ldeff(void);

int main(void)
{
	ldeff();
	printf("%a %a %a\n", ldret(), ldarg(), ldsum());
	return 0;
}

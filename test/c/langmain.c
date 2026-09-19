int replaced(void) { return 2; }
void lang(void);

/* Nothing comes back from this one, and lang.c says so.  Nothing calls
 * it either: what is being tested is what the compiler does with the
 * code after a call to it. */
void langdie(int v);
void langdie(int v) { while (v >= 0) { } }

int main(void) { lang(); return 0; }

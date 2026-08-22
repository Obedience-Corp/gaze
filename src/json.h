#ifndef GAZE_JSON_H
#define GAZE_JSON_H

#include <stddef.h>

typedef enum { JNULL, JBOOL, JNUM, JSTR, JARR, JOBJ } JType;

typedef struct JVal JVal;
struct JVal {
    JType t;
    int b;
    char *s;     /* JSTR, and JNUM lexeme */
    JVal *head;  /* JARR/JOBJ children */
    JVal *next;
    char *k;     /* object member key */
};

JVal *jparse(const char *s);
void jfree(JVal *v);
JVal *jobj(const JVal *o, const char *key);
const char *jstr(const JVal *v);
int jnum_i(const JVal *v, long *out);

#endif

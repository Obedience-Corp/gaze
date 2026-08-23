#include "json.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

static const char *skip(const char *s) {
    while (*s && isspace((unsigned char)*s)) s++;
    return s;
}

static JVal *node(JType t) {
    JVal *v = calloc(1, sizeof(*v));
    if (v) v->t = t;
    return v;
}

static const char *parse_val(const char *s, JVal **out);

static char *dupn(const char *s, size_t n) {
    char *d = malloc(n + 1);
    if (!d) return NULL;
    memcpy(d, s, n);
    d[n] = 0;
    return d;
}

static const char *parse_str(const char *s, char **out) {
    if (*s != '"') return NULL;
    s++;
    const char *start = s;
    char buf[4096];
    size_t n = 0;
    while (*s && *s != '"') {
        if (n + 1 >= sizeof(buf)) return NULL;
        if (*s == '\\' && s[1]) {
            s++;
            char c = *s++;
            if (c == 'n') c = '\n';
            else if (c == 't') c = '\t';
            else if (c == 'r') c = '\r';
            buf[n++] = c;
        } else {
            buf[n++] = *s++;
        }
    }
    if (*s != '"') return NULL;
    (void)start;
    *out = dupn(buf, n);
    return *out ? s + 1 : NULL;
}

static const char *parse_num(const char *s, JVal *v) {
    const char *b = s;
    if (*s == '-') s++;
    if (!isdigit((unsigned char)*s)) return NULL;
    while (isdigit((unsigned char)*s)) s++;
    if (*s == '.') {
        s++;
        while (isdigit((unsigned char)*s)) s++;
    }
    v->s = dupn(b, (size_t)(s - b));
    return v->s ? s : NULL;
}

static const char *parse_obj(const char *s, JVal *v) {
    s = skip(s + 1);
    JVal **tail = &v->head;
    if (*s == '}') return s + 1;
    for (;;) {
        s = skip(s);
        char *k = NULL;
        s = parse_str(s, &k);
        if (!s) return NULL;
        s = skip(s);
        if (*s != ':') {
            free(k);
            return NULL;
        }
        JVal *child = NULL;
        s = parse_val(skip(s + 1), &child);
        if (!s || !child) {
            free(k);
            return NULL;
        }
        child->k = k;
        *tail = child;
        tail = &child->next;
        s = skip(s);
        if (*s == ',') {
            s++;
            continue;
        }
        if (*s == '}') return s + 1;
        return NULL;
    }
}

static const char *parse_arr(const char *s, JVal *v) {
    s = skip(s + 1);
    JVal **tail = &v->head;
    if (*s == ']') return s + 1;
    for (;;) {
        JVal *child = NULL;
        s = parse_val(skip(s), &child);
        if (!s || !child) return NULL;
        *tail = child;
        tail = &child->next;
        s = skip(s);
        if (*s == ',') {
            s++;
            continue;
        }
        if (*s == ']') return s + 1;
        return NULL;
    }
}

static const char *parse_val(const char *s, JVal **out) {
    s = skip(s);
    JVal *v = NULL;
    if (*s == '"') {
        v = node(JSTR);
        if (!v) return NULL;
        s = parse_str(s, &v->s);
    } else if (*s == '{') {
        v = node(JOBJ);
        if (!v) return NULL;
        s = parse_obj(s, v);
    } else if (*s == '[') {
        v = node(JARR);
        if (!v) return NULL;
        s = parse_arr(s, v);
    } else if (*s == '-' || isdigit((unsigned char)*s)) {
        v = node(JNUM);
        if (!v) return NULL;
        s = parse_num(s, v);
    } else if (strncmp(s, "true", 4) == 0) {
        v = node(JBOOL);
        if (!v) return NULL;
        v->b = 1;
        s += 4;
    } else if (strncmp(s, "false", 5) == 0) {
        v = node(JBOOL);
        if (!v) return NULL;
        s += 5;
    } else if (strncmp(s, "null", 4) == 0) {
        v = node(JNULL);
        if (!v) return NULL;
        s += 4;
    } else {
        return NULL;
    }
    if (!s) {
        jfree(v);
        return NULL;
    }
    *out = v;
    return s;
}

JVal *jparse(const char *s) {
    JVal *v = NULL;
    const char *end = parse_val(s, &v);
    if (!end) {
        jfree(v);
        return NULL;
    }
    end = skip(end);
    if (*end && *end != '\n' && *end != '\r') {
        jfree(v);
        return NULL;
    }
    return v;
}

void jfree(JVal *v) {
    while (v) {
        JVal *n = v->next;
        jfree(v->head);
        free(v->s);
        free(v->k);
        free(v);
        v = n;
    }
}

JVal *jobj(const JVal *o, const char *key) {
    if (!o || o->t != JOBJ || !key) return NULL;
    for (JVal *c = o->head; c; c = c->next) {
        if (c->k && strcmp(c->k, key) == 0) return c;
    }
    return NULL;
}

const char *jstr(const JVal *v) {
    if (!v || v->t != JSTR) return NULL;
    return v->s;
}

int jnum_i(const JVal *v, long *out) {
    if (!v || v->t != JNUM || !v->s) return -1;
    char *e = NULL;
    *out = strtol(v->s, &e, 10);
    return 0;
}

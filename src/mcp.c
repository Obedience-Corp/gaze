#include "gaze.h"
#include "json.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static GazeCam *g_cam;
static uint16_t g_vid, g_pid;

static GazeCam *cam(void) {
    if (!g_cam) g_cam = gaze_open(g_vid, g_pid);
    return g_cam;
}

static GazeCam *cam_reopen(void) {
    if (g_cam) {
        gaze_close(g_cam);
        g_cam = NULL;
    }
    return cam();
}

static void emit(const char *s) {
    fputs(s, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void reply_ok(const char *id, const char *body) {
    size_t n = strlen(id) + strlen(body) + 40;
    char *line = malloc(n);
    if (!line) return;
    snprintf(line, n, "{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":%s}", id, body);
    emit(line);
    free(line);
}

static void reply_err(const char *id, int code, const char *msg) {
    char line[1024];
    snprintf(line, sizeof(line),
             "{\"jsonrpc\":\"2.0\",\"id\":%s,\"error\":{\"code\":%d,\"message\":\"%s\"}}",
             id, code, msg);
    emit(line);
}

static char *b64enc(const uint8_t *src, size_t n, size_t *outn) {
    static const char T[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 4 * ((n + 2) / 3);
    char *d = malloc(o + 1);
    if (!d) return NULL;
    size_t i = 0, j = 0;
    while (i + 3 <= n) {
        unsigned t = ((unsigned)src[i] << 16) | ((unsigned)src[i + 1] << 8) | src[i + 2];
        i += 3;
        d[j++] = T[(t >> 18) & 63];
        d[j++] = T[(t >> 12) & 63];
        d[j++] = T[(t >> 6) & 63];
        d[j++] = T[t & 63];
    }
    if (i < n) {
        unsigned t = (unsigned)src[i] << 16;
        if (i + 1 < n) t |= (unsigned)src[i + 1] << 8;
        d[j++] = T[(t >> 18) & 63];
        d[j++] = T[(t >> 12) & 63];
        d[j++] = (i + 1 < n) ? T[(t >> 6) & 63] : '=';
        d[j++] = '=';
    }
    d[j] = 0;
    if (outn) *outn = j;
    return d;
}

static void json_escape(const char *in, char *out, size_t n) {
    size_t i = 0;
    for (; *in && i + 2 < n; in++) {
        if (*in == '"' || *in == '\\') {
            out[i++] = '\\';
            out[i++] = *in;
        } else if ((unsigned char)*in < 0x20) {
            continue;
        } else {
            out[i++] = *in;
        }
    }
    out[i] = 0;
}

static void id_emit(const JVal *idv, char *out, size_t n) {
    if (!idv || idv->t == JNULL) {
        snprintf(out, n, "null");
        return;
    }
    if (idv->t == JNUM && idv->s) {
        snprintf(out, n, "%s", idv->s);
        return;
    }
    if (idv->t == JSTR && idv->s) {
        char esc[128];
        json_escape(idv->s, esc, sizeof(esc));
        snprintf(out, n, "\"%s\"", esc);
        return;
    }
    snprintf(out, n, "null");
}

static void tool_text(const char *id, const char *text, int is_err) {
    char esc[512];
    char body[768];
    json_escape(text, esc, sizeof(esc));
    snprintf(body, sizeof(body),
             "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"%s\"}]%s}",
             esc, is_err ? ",\"isError\":true" : "");
    reply_ok(id, body);
}

static void tool_see(const char *id, const char *text, const uint8_t *jpeg, size_t n) {
    size_t b64n = 0;
    char *b64 = b64enc(jpeg, n, &b64n);
    if (!b64) {
        tool_text(id, "oom", 1);
        return;
    }
    char esc[256];
    json_escape(text, esc, sizeof(esc));
    size_t cap = b64n + 256;
    char *body = malloc(cap);
    if (!body) {
        free(b64);
        tool_text(id, "oom", 1);
        return;
    }
    snprintf(body, cap,
             "{\"resultType\":\"complete\",\"content\":["
             "{\"type\":\"text\",\"text\":\"%s\"},"
             "{\"type\":\"image\",\"mimeType\":\"image/jpeg\",\"data\":\"%s\"}]}",
             esc, b64);
    reply_ok(id, body);
    free(body);
    free(b64);
}

static const char *TOOLS =
    "{\"resultType\":\"complete\",\"tools\":[{\"name\":\"g\","
    "\"description\":\"PTZ+see. q: v|s|c|z N|p N|t N. v=jpeg. Moves return z=p=t.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{"
    "\"q\":{\"type\":\"string\"}},\"required\":[\"q\"],"
    "\"additionalProperties\":false}}]}";

static const char *INIT_CAP =
    "{\"resultType\":\"complete\",\"protocolVersion\":\"%s\","
    "\"capabilities\":{\"tools\":{\"listChanged\":false}},"
    "\"serverInfo\":{\"name\":\"gaze\",\"version\":\"" GAZE_VERSION "\"},"
    "\"instructions\":\"g. q=v jpeg (eyes), s status, c center, z N zoom, p N pan, t N tilt. "
    "Never status after a move.\"}";

static void split_q(char *q, int *argc, char **argv, int max) {
    *argc = 0;
    char *p = q;
    while (*p && *argc < max) {
        while (*p && isspace((unsigned char)*p)) p++;
        if (!*p) break;
        argv[(*argc)++] = p;
        while (*p && !isspace((unsigned char)*p)) p++;
        if (*p) *p++ = 0;
    }
}

static void do_g(const char *id, const char *q0) {
    GazeCam *c = cam();
    if (!c) {
        c = cam_reopen();
        if (!c) {
            tool_text(id, gaze_error(), 1);
            return;
        }
    }
    char qbuf[128];
    snprintf(qbuf, sizeof(qbuf), "%s", q0 ? q0 : "s");
    int argc = 0;
    char *argv[8];
    split_q(qbuf, &argc, argv, 8);
    if (argc == 0) argv[argc++] = "s";
    int want_see = (strcmp(argv[0], "v") == 0 || strcmp(argv[0], "see") == 0);
    char out[128];
    if (gaze_cmd(c, argc, argv, out, sizeof(out)) != 0) {
        c = cam_reopen();
        if (!c || gaze_cmd(c, argc, argv, out, sizeof(out)) != 0) {
            tool_text(id, gaze_error()[0] ? gaze_error() : "bad q", 1);
            return;
        }
    }
    if (want_see) {
        uint8_t *jpeg = NULL;
        size_t n = 0;
        if (gaze_snap(c, &jpeg, &n) != 0) {
            tool_text(id, gaze_error()[0] ? gaze_error() : "no frame", 1);
            return;
        }
        tool_see(id, out, jpeg, n);
        free(jpeg);
        return;
    }
    tool_text(id, out, 0);
}

int gaze_mcp(uint16_t vid, uint16_t pid) {
    g_vid = vid;
    g_pid = pid;
    char *line = NULL;
    size_t cap = 0;
    setvbuf(stdin, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IOLBF, 0);
    while (getline(&line, &cap, stdin) >= 0) {
        if (!line[0] || line[0] == '\n') continue;
        JVal *root = jparse(line);
        if (!root) {
            reply_err("null", -32700, "parse error");
            continue;
        }
        char id[64];
        id_emit(jobj(root, "id"), id, sizeof(id));
        const char *method = jstr(jobj(root, "method"));
        if (!method) {
            if (jobj(root, "id")) reply_err(id, -32600, "no method");
            jfree(root);
            continue;
        }
        if (strncmp(method, "notifications/", 14) == 0) {
            jfree(root);
            continue;
        }
        JVal *params = jobj(root, "params");
        if (strcmp(method, "initialize") == 0 || strcmp(method, "server/discover") == 0) {
            char ver[32] = "2025-03-26";
            const char *pv = jstr(jobj(params, "protocolVersion"));
            if (!pv) pv = jstr(jobj(root, "protocolVersion"));
            if (pv && pv[0]) snprintf(ver, sizeof(ver), "%s", pv);
            char body[768];
            snprintf(body, sizeof(body), INIT_CAP, ver);
            reply_ok(id, body);
        } else if (strcmp(method, "ping") == 0) {
            reply_ok(id, "{}");
        } else if (strcmp(method, "tools/list") == 0) {
            reply_ok(id, TOOLS);
        } else if (strcmp(method, "tools/call") == 0) {
            const char *name = jstr(jobj(params, "name"));
            const char *q = jstr(jobj(jobj(params, "arguments"), "q"));
            if (name && strcmp(name, "g") != 0 && strcmp(name, "gaze") != 0) {
                tool_text(id, "unknown tool", 1);
            } else {
                do_g(id, q);
            }
        } else if (strcmp(method, "resources/list") == 0) {
            reply_ok(id, "{\"resources\":[]}");
        } else if (strcmp(method, "prompts/list") == 0) {
            reply_ok(id, "{\"prompts\":[]}");
        } else {
            reply_err(id, -32601, "unknown");
        }
        jfree(root);
    }
    free(line);
    if (g_cam) gaze_close(g_cam);
    return 0;
}

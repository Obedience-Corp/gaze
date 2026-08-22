#include "gaze.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* One-tool stdio MCP. Newline JSON-RPC. No SDK. */

static GazeCam *g_cam;

static GazeCam *cam(void) {
    if (!g_cam) g_cam = gaze_open(0, 0);
    return g_cam;
}

static GazeCam *cam_reopen(void) {
    if (g_cam) {
        gaze_close(g_cam);
        g_cam = NULL;
    }
    return cam();
}

static const char *json_skip(const char *s) {
    while (*s && isspace((unsigned char)*s)) s++;
    return s;
}

static int json_raw_id(const char *js, char *out, size_t n) {
    const char *k = strstr(js, "\"id\"");
    if (!k) {
        snprintf(out, n, "null");
        return 0;
    }
    k = strchr(k + 4, ':');
    if (!k) return -1;
    k = json_skip(k + 1);
    if (*k == '"') {
        size_t i = 0;
        out[i++] = '"';
        k++;
        while (*k && *k != '"' && i + 2 < n) {
            if (*k == '\\' && k[1]) {
                out[i++] = *k++;
                out[i++] = *k++;
            } else {
                out[i++] = *k++;
            }
        }
        out[i++] = '"';
        out[i] = 0;
        return 0;
    }
    size_t i = 0;
    while (*k && *k != ',' && *k != '}' && *k != ']' && i + 1 < n) {
        if (!isspace((unsigned char)*k)) out[i++] = *k;
        k++;
    }
    out[i] = 0;
    if (!out[0]) snprintf(out, n, "null");
    return 0;
}

static int json_str(const char *js, const char *key, char *out, size_t n) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *k = js;
    for (;;) {
        k = strstr(k, pat);
        if (!k) return -1;
        const char *colon = strchr(k + strlen(pat), ':');
        if (!colon) return -1;
        colon = json_skip(colon + 1);
        if (*colon != '"') {
            k += strlen(pat);
            continue;
        }
        colon++;
        size_t i = 0;
        while (*colon && *colon != '"' && i + 1 < n) {
            if (*colon == '\\' && colon[1]) {
                colon++;
                out[i++] = *colon++;
            } else {
                out[i++] = *colon++;
            }
        }
        out[i] = 0;
        return 0;
    }
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

static void reply_err(const char *id, int code, const char *msg) {
    char line[1024];
    snprintf(line, sizeof(line),
             "{\"jsonrpc\":\"2.0\",\"id\":%s,\"error\":{\"code\":%d,\"message\":\"%s\"}}",
             id, code, msg);
    emit(line);
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
    "\"serverInfo\":{\"name\":\"gaze\",\"version\":\"0.1.0\"},"
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

static void do_g(const char *id, char *q) {
    GazeCam *c = cam();
    if (!c) {
        c = cam_reopen();
        if (!c) {
            tool_text(id, gaze_error(), 1);
            return;
        }
    }
    int argc = 0;
    char *argv[8];
    split_q(q, &argc, argv, 8);
    if (argc == 0) {
        argv[argc++] = "s";
    }
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

int gaze_mcp(void) {
    char *line = NULL;
    size_t cap = 0;
    setvbuf(stdin, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IOLBF, 0);
    while (getline(&line, &cap, stdin) >= 0) {
        if (!line[0] || line[0] == '\n') continue;
        char id[64];
        char method[64];
        json_raw_id(line, id, sizeof(id));
        if (json_str(line, "method", method, sizeof(method)) != 0) {
            if (strstr(line, "\"id\"")) reply_err(id, -32600, "no method");
            continue;
        }
        if (strcmp(method, "initialize") == 0 || strcmp(method, "server/discover") == 0) {
            char ver[32] = "2025-03-26";
            char pver[32];
            if (json_str(line, "protocolVersion", pver, sizeof(pver)) == 0 && pver[0]) {
                snprintf(ver, sizeof(ver), "%s", pver);
            }
            char body[768];
            snprintf(body, sizeof(body), INIT_CAP, ver);
            reply_ok(id, body);
        } else if (strcmp(method, "notifications/initialized") == 0 ||
                   strcmp(method, "notifications/cancelled") == 0) {
            continue;
        } else if (strcmp(method, "ping") == 0) {
            reply_ok(id, "{}");
        } else if (strcmp(method, "tools/list") == 0) {
            reply_ok(id, TOOLS);
        } else if (strcmp(method, "tools/call") == 0) {
            char name[32] = {0};
            char q[128] = {0};
            json_str(line, "name", name, sizeof(name));
            json_str(line, "q", q, sizeof(q));
            if (name[0] && strcmp(name, "g") != 0 && strcmp(name, "gaze") != 0) {
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
    }
    free(line);
    if (g_cam) gaze_close(g_cam);
    return 0;
}

#include "uvc_parse.h"
#include "gaze.h"
#include <stdio.h>
#include <string.h>

static char g_err[160];

const char *gaze_error(void) { return g_err; }

void gaze_set_error(const char *msg) {
    snprintf(g_err, sizeof(g_err), "%s", msg ? msg : "");
}

void gaze_set_errorf(const char *fmt, int code) {
    snprintf(g_err, sizeof(g_err), "%s (0x%x)", fmt, code);
}

int gaze_parse_devid(const char *s, uint16_t *vid, uint16_t *pid) {
    unsigned v = 0, p = 0;
    if (!s || sscanf(s, "%x:%x", &v, &p) != 2) return -1;
    *vid = (uint16_t)v;
    *pid = (uint16_t)p;
    return 0;
}

int uvc_parse_config(const uint8_t *cfg, size_t n, GazeInfo *info) {
    const uint8_t *p = cfg;
    const uint8_t *end = cfg + n;
    uint8_t iface = 0xFF, cls = 0, sub = 0;

    /* sysfs blobs start with the device descriptor; skip to configuration. */
    while (p + 2 <= end && p[1] != 0x02) {
        uint8_t len = p[0];
        if (len < 2) return -1;
        p += len;
    }
    if (p + 4 > end || p[1] != 0x02) return -1;

    uint16_t total = (uint16_t)(p[2] | (p[3] << 8));
    if (p + total > end) total = (uint16_t)(end - p);
    end = p + total;

    info->vc_iface = 0xFF;
    info->camera_unit = 0xFF;
    info->xu_unit = 0;
    info->xu_mode_sel = 0;
    info->xu_mode_len = 0;

    while (p + 2 <= end) {
        uint8_t len = p[0];
        uint8_t typ = p[1];
        if (len < 2 || p + len > end) break;
        if (typ == 0x04 && len >= 9) {
            iface = p[2];
            cls = p[5];
            sub = p[6];
            if (cls == 14 && sub == 1) info->vc_iface = iface;
        }
        if (typ == CS_INTERFACE && cls == 14 && sub == 1 && len >= 8) {
            uint8_t st = p[2];
            if (st == VC_INPUT_TERMINAL) {
                uint16_t tt = (uint16_t)(p[4] | (p[5] << 8));
                if (tt == ITT_CAMERA) info->camera_unit = p[3];
            } else if (st == VC_EXTENSION_UNIT && len >= 24 && p[3] == UVC_XU_INSTA360) {
                info->xu_unit = p[3];
                info->xu_mode_sel = UVC_XU_MODE_SEL;
            }
        }
        p += len;
    }
    return (info->vc_iface != 0xFF && info->camera_unit != 0xFF) ? 0 : -1;
}

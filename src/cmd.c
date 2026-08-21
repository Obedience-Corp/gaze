#include "gaze.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int parse_rel(const char *s, long cur, long *out) {
    if (!s || !*s) return -1;
    if (s[0] == '+' || (s[0] == '-' && s[1])) {
        *out = cur + strtol(s, NULL, 10);
        return 0;
    }
    *out = strtol(s, NULL, 10);
    return 0;
}

int gaze_line(GazeCam *cam, char *buf, size_t n) {
    GazeInfo inf;
    uint16_t z = 0;
    int32_t pan = 0, tilt = 0;
    if (gaze_info(cam, &inf) != 0) return -1;
    if (gaze_get_zoom(cam, &z) != 0) return -1;
    if (gaze_get_pantilt(cam, &pan, &tilt) != 0) return -1;
    snprintf(buf, n, "%04x:%04x z=%u p=%d t=%d", inf.vid, inf.pid, z, pan, tilt);
    return 0;
}

static int cmd_center(GazeCam *cam) {
    uint16_t zmin = 0, zmax = 0, zdef = 100;
    gaze_zoom_range(cam, &zmin, &zmax, &zdef);
    if (gaze_set_pantilt(cam, 0, 0) != 0) return -1;
    if (gaze_set_zoom(cam, zdef) != 0) return -1;
    return 0;
}

static int cmd_zoom(GazeCam *cam, const char *arg) {
    uint16_t cur = 0, zmin = 0, zmax = 0, zdef = 0;
    long next = 0;
    if (gaze_get_zoom(cam, &cur) != 0) return -1;
    if (gaze_zoom_range(cam, &zmin, &zmax, &zdef) != 0) return -1;
    if (parse_rel(arg, cur, &next) != 0) return -1;
    if (next < zmin) next = zmin;
    if (next > zmax) next = zmax;
    return gaze_set_zoom(cam, (uint16_t)next);
}

static int cmd_axis(GazeCam *cam, int pan_axis, const char *arg) {
    int32_t pan = 0, tilt = 0, pmin = 0, pmax = 0, tmin = 0, tmax = 0;
    long next = 0;
    if (gaze_get_pantilt(cam, &pan, &tilt) != 0) return -1;
    if (gaze_pantilt_range(cam, &pmin, &pmax, &tmin, &tmax) != 0) return -1;
    if (parse_rel(arg, pan_axis ? pan : tilt, &next) != 0) return -1;
    if (pan_axis) {
        if (next < pmin) next = pmin;
        if (next > pmax) next = pmax;
        pan = (int32_t)next;
    } else {
        if (next < tmin) next = tmin;
        if (next > tmax) next = tmax;
        tilt = (int32_t)next;
    }
    return gaze_set_pantilt(cam, pan, tilt);
}

static int on_off(const char *s) {
    if (!s) return 1;
    if (strcmp(s, "on") == 0 || strcmp(s, "1") == 0) return 1;
    if (strcmp(s, "off") == 0 || strcmp(s, "0") == 0) return 0;
    return -1;
}

int gaze_cmd(GazeCam *cam, int argc, char **argv, char *out, size_t n) {
    const char *v = (argc >= 1) ? argv[0] : "s";
    int rc = 0;
    if (strcmp(v, "s") == 0 || strcmp(v, "status") == 0) {
        rc = 0;
    } else if (strcmp(v, "c") == 0 || strcmp(v, "center") == 0) {
        rc = cmd_center(cam);
    } else if (strcmp(v, "z") == 0 || strcmp(v, "zoom") == 0) {
        if (argc < 2) return -1;
        rc = cmd_zoom(cam, argv[1]);
    } else if (strcmp(v, "p") == 0 || strcmp(v, "pan") == 0) {
        if (argc < 2) return -1;
        rc = cmd_axis(cam, 1, argv[1]);
    } else if (strcmp(v, "t") == 0 || strcmp(v, "tilt") == 0) {
        if (argc < 2) return -1;
        rc = cmd_axis(cam, 0, argv[1]);
    } else if (strcmp(v, "normal") == 0) {
        rc = gaze_set_mode(cam, 0x00, 0x00);
    } else if (strcmp(v, "track") == 0 || strcmp(v, "tr") == 0) {
        int on = on_off(argc >= 2 ? argv[1] : "on");
        if (on < 0) return -1;
        rc = on ? gaze_set_mode(cam, 0x01, 0x00) : gaze_set_mode(cam, 0x00, 0x00);
    } else if (strcmp(v, "deskview") == 0) {
        int on = on_off(argc >= 2 ? argv[1] : "on");
        if (on < 0) return -1;
        rc = on ? gaze_set_mode(cam, 0x06, 0x10) : gaze_set_mode(cam, 0x00, 0x00);
    } else if (strcmp(v, "overhead") == 0) {
        int on = on_off(argc >= 2 ? argv[1] : "on");
        if (on < 0) return -1;
        rc = on ? gaze_set_mode(cam, 0x05, 0x03) : gaze_set_mode(cam, 0x00, 0x00);
    } else if (strcmp(v, "whiteboard") == 0) {
        int on = on_off(argc >= 2 ? argv[1] : "on");
        if (on < 0) return -1;
        rc = on ? gaze_set_mode(cam, 0x04, 0x01) : gaze_set_mode(cam, 0x00, 0x00);
    } else {
        return -1;
    }
    if (rc != 0) return -1;
    return gaze_line(cam, out, n);
}

#include "gaze.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void die(const char *ctx) {
    fprintf(stderr, "gaze: %s: %s\n", ctx, gaze_error());
    exit(2);
}

static void usage(void) {
    fprintf(stderr,
            "gaze — native PTZ. no vendor app.\n"
            "\n"
            "  gaze              status\n"
            "  gaze status\n"
            "  gaze center\n"
            "  gaze zoom <n|+n|-n>     100–400 typical\n"
            "  gaze pan <n|+n|-n>\n"
            "  gaze tilt <n|+n|-n>\n"
            "  gaze track on|off\n"
            "  gaze deskview on|off\n"
            "  gaze overhead on|off\n"
            "  gaze whiteboard on|off\n"
            "  gaze normal\n"
            "\n"
            "Talks USB Video Class on the device. Quit the vendor controller first.\n");
}

static GazeCam *must_open(void) {
    GazeCam *cam = gaze_open(0, 0);
    if (!cam) die("open");
    return cam;
}

static int parse_rel(const char *s, long cur, long *out) {
    if (s[0] == '+' || s[0] == '-') {
        *out = cur + strtol(s, NULL, 10);
        return 0;
    }
    *out = strtol(s, NULL, 10);
    return 0;
}

static const char *mode_name(uint8_t b0, uint8_t b1) {
    if (b0 == 0x00 && b1 == 0x00) return "normal";
    if (b0 == 0x01) return "track";
    if (b0 == 0x04) return "whiteboard";
    if (b0 == 0x05) return "overhead";
    if (b0 == 0x06) return "deskview";
    (void)b1;
    return "unknown";
}

static int cmd_status(GazeCam *cam) {
    GazeInfo inf;
    if (gaze_info(cam, &inf) != 0) die("info");
    uint16_t z = 0, zmin = 0, zmax = 0, zdef = 0;
    int32_t pan = 0, tilt = 0, pmin = 0, pmax = 0, tmin = 0, tmax = 0;
    if (gaze_get_zoom(cam, &z) != 0) die("zoom");
    if (gaze_zoom_range(cam, &zmin, &zmax, &zdef) != 0) die("zoom-range");
    if (gaze_get_pantilt(cam, &pan, &tilt) != 0) die("pantilt");
    if (gaze_pantilt_range(cam, &pmin, &pmax, &tmin, &tmax) != 0) die("pantilt-range");
    printf("%s  %04x:%04x\n", inf.name, inf.vid, inf.pid);
    printf("zoom    %u  (%u–%u)\n", z, zmin, zmax);
    printf("pan     %d  (%d–%d)\n", pan, pmin, pmax);
    printf("tilt    %d  (%d–%d)\n", tilt, tmin, tmax);
    if (inf.xu_unit) {
        uint8_t b0 = 0, b1 = 0;
        if (gaze_get_mode(cam, &b0, &b1) == 0) {
            printf("mode    %s  (%02x %02x)\n", mode_name(b0, b1), b0, b1);
        }
    }
    return 0;
}

static int cmd_center(GazeCam *cam) {
    uint16_t zmin = 0, zmax = 0, zdef = 100;
    gaze_zoom_range(cam, &zmin, &zmax, &zdef);
    if (gaze_set_pantilt(cam, 0, 0) != 0) die("center pan/tilt");
    if (gaze_set_zoom(cam, zdef) != 0) die("center zoom");
    printf("center\n");
    return 0;
}

static int cmd_zoom(GazeCam *cam, const char *arg) {
    uint16_t cur = 0, zmin = 0, zmax = 0, zdef = 0;
    if (gaze_get_zoom(cam, &cur) != 0) die("zoom");
    if (gaze_zoom_range(cam, &zmin, &zmax, &zdef) != 0) die("zoom-range");
    long next = 0;
    parse_rel(arg, cur, &next);
    if (next < zmin) next = zmin;
    if (next > zmax) next = zmax;
    if (gaze_set_zoom(cam, (uint16_t)next) != 0) die("set zoom");
    printf("zoom %ld\n", next);
    return 0;
}

static int cmd_axis(GazeCam *cam, int pan_axis, const char *arg) {
    int32_t pan = 0, tilt = 0, pmin = 0, pmax = 0, tmin = 0, tmax = 0;
    if (gaze_get_pantilt(cam, &pan, &tilt) != 0) die("pantilt");
    if (gaze_pantilt_range(cam, &pmin, &pmax, &tmin, &tmax) != 0) die("pantilt-range");
    long next = 0;
    parse_rel(arg, pan_axis ? pan : tilt, &next);
    if (pan_axis) {
        if (next < pmin) next = pmin;
        if (next > pmax) next = pmax;
        pan = (int32_t)next;
    } else {
        if (next < tmin) next = tmin;
        if (next > tmax) next = tmax;
        tilt = (int32_t)next;
    }
    if (gaze_set_pantilt(cam, pan, tilt) != 0) die("set pantilt");
    printf("%s %ld\n", pan_axis ? "pan" : "tilt", next);
    return 0;
}

static int cmd_mode(GazeCam *cam, uint8_t b0, uint8_t b1, const char *label) {
    if (gaze_set_mode(cam, b0, b1) != 0) die(label);
    printf("%s\n", label);
    return 0;
}

static int on_off(const char *s) {
    if (!s) return -1;
    if (strcmp(s, "on") == 0) return 1;
    if (strcmp(s, "off") == 0) return 0;
    return -1;
}

int main(int argc, char **argv) {
    if (argc >= 2 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        usage();
        return 0;
    }
    const char *cmd = (argc >= 2) ? argv[1] : "status";
    GazeCam *cam = must_open();
    int rc = 0;
    if (strcmp(cmd, "status") == 0) {
        rc = cmd_status(cam);
    } else if (strcmp(cmd, "center") == 0) {
        rc = cmd_center(cam);
    } else if (strcmp(cmd, "zoom") == 0) {
        if (argc < 3) {
            usage();
            rc = 1;
        } else {
            rc = cmd_zoom(cam, argv[2]);
        }
    } else if (strcmp(cmd, "pan") == 0) {
        if (argc < 3) {
            usage();
            rc = 1;
        } else {
            rc = cmd_axis(cam, 1, argv[2]);
        }
    } else if (strcmp(cmd, "tilt") == 0) {
        if (argc < 3) {
            usage();
            rc = 1;
        } else {
            rc = cmd_axis(cam, 0, argv[2]);
        }
    } else if (strcmp(cmd, "normal") == 0) {
        rc = cmd_mode(cam, 0x00, 0x00, "normal");
    } else if (strcmp(cmd, "track") == 0) {
        int v = (argc >= 3) ? on_off(argv[2]) : 1;
        if (v < 0) {
            usage();
            rc = 1;
        } else {
            rc = v ? cmd_mode(cam, 0x01, 0x00, "track on") : cmd_mode(cam, 0x00, 0x00, "track off");
        }
    } else if (strcmp(cmd, "whiteboard") == 0) {
        int v = (argc >= 3) ? on_off(argv[2]) : 1;
        if (v < 0) {
            usage();
            rc = 1;
        } else {
            rc = v ? cmd_mode(cam, 0x04, 0x01, "whiteboard on")
                   : cmd_mode(cam, 0x00, 0x00, "whiteboard off");
        }
    } else if (strcmp(cmd, "overhead") == 0) {
        int v = (argc >= 3) ? on_off(argv[2]) : 1;
        if (v < 0) {
            usage();
            rc = 1;
        } else {
            rc = v ? cmd_mode(cam, 0x05, 0x03, "overhead on")
                   : cmd_mode(cam, 0x00, 0x00, "overhead off");
        }
    } else if (strcmp(cmd, "deskview") == 0) {
        int v = (argc >= 3) ? on_off(argv[2]) : 1;
        if (v < 0) {
            usage();
            rc = 1;
        } else {
            rc = v ? cmd_mode(cam, 0x06, 0x10, "deskview on")
                   : cmd_mode(cam, 0x00, 0x00, "deskview off");
        }
    } else {
        usage();
        rc = 1;
    }
    gaze_close(cam);
    return rc;
}

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
            "gaze — USB cameras for agents. gimbal optional.\n"
            "\n"
            "  gaze list\n"
            "  gaze [-d vid:pid] status\n"
            "  gaze [-d vid:pid] see [file]\n"
            "  gaze [-d vid:pid] center\n"
            "  gaze [-d vid:pid] zoom <n|+n|-n>\n"
            "  gaze [-d vid:pid] pan <n|+n|-n>\n"
            "  gaze [-d vid:pid] tilt <n|+n|-n>\n"
            "  gaze mcp          stdio MCP (one tool: g; q=v returns a JPEG)\n"
            "\n"
            "Any UVC webcam: see. Zoom / pan / tilt if the Camera Terminal has them.\n"
            "GAZE_DEV=vid:pid selects a camera. Quit the vendor controller first.\n");
}

static int parse_devid(const char *s, uint16_t *vid, uint16_t *pid) {
    unsigned v = 0, p = 0;
    if (!s || sscanf(s, "%x:%x", &v, &p) != 2) return -1;
    *vid = (uint16_t)v;
    *pid = (uint16_t)p;
    return 0;
}

static GazeCam *must_open(uint16_t vid, uint16_t pid) {
    GazeCam *cam = gaze_open(vid, pid);
    if (!cam) die("open");
    return cam;
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
    uint16_t z = 0, zmin = 0, zmax = 0, zdef = 0;
    int32_t pan = 0, tilt = 0, pmin = 0, pmax = 0, tmin = 0, tmax = 0;
    if (gaze_info(cam, &inf) != 0) die("info");
    printf("%s  %04x:%04x\n", inf.name, inf.vid, inf.pid);
    if (inf.has_zoom) {
        if (gaze_get_zoom(cam, &z) != 0) die("zoom");
        if (gaze_zoom_range(cam, &zmin, &zmax, &zdef) != 0) die("zoom-range");
        printf("zoom    %u  (%u–%u)\n", z, zmin, zmax);
    } else {
        printf("zoom    n/a\n");
    }
    if (inf.has_pantilt) {
        if (gaze_get_pantilt(cam, &pan, &tilt) != 0) die("pantilt");
        if (gaze_pantilt_range(cam, &pmin, &pmax, &tmin, &tmax) != 0) die("pantilt-range");
        printf("pan     %d  (%d–%d)\n", pan, pmin, pmax);
        printf("tilt    %d  (%d–%d)\n", tilt, tmin, tmax);
    } else {
        printf("pan     n/a\n");
        printf("tilt    n/a\n");
    }
    if (inf.xu_unit) {
        uint8_t b0 = 0, b1 = 0;
        if (gaze_get_mode(cam, &b0, &b1) == 0) {
            printf("mode    %s  (%02x %02x)\n", mode_name(b0, b1), b0, b1);
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    int argi = 1;
    uint16_t vid = 0, pid = 0;
    if (argc >= 2 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        usage();
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "mcp") == 0) return gaze_mcp();
    if (argc >= 2 && strcmp(argv[1], "list") == 0) {
        int n = gaze_list();
        if (n < 0) die("list");
        if (n == 0) fprintf(stderr, "gaze: no UVC camera\n");
        return n > 0 ? 0 : 1;
    }
    if (argc >= 3 && strcmp(argv[1], "-d") == 0) {
        if (parse_devid(argv[2], &vid, &pid) != 0) {
            fprintf(stderr, "gaze: -d wants vid:pid in hex\n");
            return 1;
        }
        argi = 3;
    }
    const char *cmd = (argc > argi) ? argv[argi] : "status";
    GazeCam *cam = must_open(vid, pid);
    int rc = 0;
    if (strcmp(cmd, "status") == 0) {
        rc = cmd_status(cam);
    } else if (strcmp(cmd, "see") == 0 || strcmp(cmd, "v") == 0) {
        uint8_t *jpeg = NULL;
        size_t n = 0;
        if (gaze_snap(cam, &jpeg, &n) != 0) die("see");
        const char *path = (argc > argi + 1) ? argv[argi + 1] : "see.jpg";
        FILE *f = fopen(path, "wb");
        if (!f || fwrite(jpeg, 1, n, f) != n) {
            free(jpeg);
            if (f) fclose(f);
            die("write jpeg");
        }
        fclose(f);
        free(jpeg);
        char line[128];
        if (gaze_line(cam, line, sizeof(line)) == 0) printf("%s  %s\n", line, path);
        else printf("%s\n", path);
    } else {
        char line[128];
        if (gaze_cmd(cam, argc - argi, argv + argi, line, sizeof(line)) != 0) {
            if (argc < argi + 2 && (strcmp(cmd, "zoom") == 0 || strcmp(cmd, "pan") == 0 ||
                             strcmp(cmd, "tilt") == 0)) {
                usage();
                rc = 1;
            } else {
                die(cmd);
            }
        } else {
            printf("%s\n", line);
        }
    }
    gaze_close(cam);
    return rc;
}

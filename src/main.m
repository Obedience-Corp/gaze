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
            "  gaze zoom <n|+n|-n>\n"
            "  gaze pan <n|+n|-n>\n"
            "  gaze tilt <n|+n|-n>\n"
            "  gaze see [file]   JPEG from the sensor (turns the camera on)\n"
            "  gaze mcp          stdio MCP (one tool: g; q=v returns the JPEG)\n"
            "\n"
            "Talks USB Video Class. Quit the vendor controller first.\n");
}

static GazeCam *must_open(void) {
    GazeCam *cam = gaze_open(0, 0);
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

int main(int argc, char **argv) {
    if (argc >= 2 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        usage();
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "mcp") == 0) return gaze_mcp();
    const char *cmd = (argc >= 2) ? argv[1] : "status";
    GazeCam *cam = must_open();
    int rc = 0;
    if (strcmp(cmd, "status") == 0) {
        rc = cmd_status(cam);
    } else if (strcmp(cmd, "see") == 0 || strcmp(cmd, "v") == 0) {
        uint8_t *jpeg = NULL;
        size_t n = 0;
        if (gaze_snap(cam, &jpeg, &n) != 0) die("see");
        const char *path = (argc >= 3) ? argv[2] : "see.jpg";
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
        if (gaze_cmd(cam, argc - 1, argv + 1, line, sizeof(line)) != 0) {
            if (argc < 3 && (strcmp(cmd, "zoom") == 0 || strcmp(cmd, "pan") == 0 ||
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

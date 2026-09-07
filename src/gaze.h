#ifndef GAZE_H
#define GAZE_H

#include <stddef.h>
#include <stdint.h>

#define GAZE_VERSION "0.2.0"

typedef struct GazeCam GazeCam;

typedef struct {
    uint16_t vid;
    uint16_t pid;
    char name[64];
    uint8_t vc_iface;
    uint8_t camera_unit;
    uint8_t xu_unit;     /* 0 = no vendor XU */
    uint8_t xu_mode_sel; /* AI / mode selector */
    uint16_t xu_mode_len;
    uint8_t has_zoom;
    uint8_t has_pantilt;
} GazeInfo;

int gaze_parse_devid(const char *s, uint16_t *vid, uint16_t *pid);

GazeCam *gaze_open(uint16_t vid, uint16_t pid); /* 0,0 = env GAZE_DEV or best UVC */
void gaze_close(GazeCam *cam);
int gaze_list(void); /* print UVC cameras to stdout; returns count */

int gaze_info(GazeCam *cam, GazeInfo *out);

int gaze_get_zoom(GazeCam *cam, uint16_t *zoom);
int gaze_set_zoom(GazeCam *cam, uint16_t zoom);
int gaze_zoom_range(GazeCam *cam, uint16_t *min, uint16_t *max, uint16_t *defv);

int gaze_get_pantilt(GazeCam *cam, int32_t *pan, int32_t *tilt);
int gaze_set_pantilt(GazeCam *cam, int32_t pan, int32_t tilt);
int gaze_pantilt_range(GazeCam *cam, int32_t *pmin, int32_t *pmax, int32_t *tmin, int32_t *tmax);

/* Vendor AI mode on cameras that expose XU unit 9 selector 2. */
int gaze_get_mode(GazeCam *cam, uint8_t *b0, uint8_t *b1);
int gaze_set_mode(GazeCam *cam, uint8_t b0, uint8_t b1);

const char *gaze_error(void);
void gaze_set_error(const char *msg);
void gaze_set_errorf(const char *fmt, int code);

/* JPEG snapshot bound to cam's vid:pid. Caller free()s *jpeg. */
int gaze_snap(GazeCam *cam, uint8_t **jpeg, size_t *len);

/* Compact one-liner: "2e1a:4c04 z=100 p=0 t=0" */
int gaze_line(GazeCam *cam, char *buf, size_t n);

/* Run one command on an open cam. argv[0] is the verb. Writes gaze_line into out. */
int gaze_cmd(GazeCam *cam, int argc, char **argv, char *out, size_t n);

int gaze_mcp(uint16_t vid, uint16_t pid);

#endif

#ifndef GAZE_H
#define GAZE_H

#include <stdint.h>

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
} GazeInfo;

GazeCam *gaze_open(uint16_t vid, uint16_t pid); /* 0,0 = first UVC PTZ */
void gaze_close(GazeCam *cam);

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

#endif

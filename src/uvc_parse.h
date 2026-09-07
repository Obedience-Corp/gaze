#ifndef GAZE_UVC_PARSE_H
#define GAZE_UVC_PARSE_H

#include "gaze.h"
#include <stddef.h>
#include <stdint.h>

#define RC_SET_CUR 0x01
#define RC_GET_CUR 0x81
#define RC_GET_MIN 0x82
#define RC_GET_MAX 0x83
#define RC_GET_LEN 0x85
#define RC_GET_DEF 0x87

#define CS_INTERFACE 0x24
#define VC_INPUT_TERMINAL 0x02
#define VC_EXTENSION_UNIT 0x06
#define ITT_CAMERA 0x0201

#define CT_ZOOM_ABSOLUTE 0x0B
#define CT_PANTILT_ABSOLUTE 0x0D

#define UVC_XU_INSTA360 9
#define UVC_XU_MODE_SEL 2

int uvc_parse_config(const uint8_t *cfg, size_t n, GazeInfo *info);

static inline int32_t uvc_le_i32(const uint8_t *b) {
    return (int32_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) |
                     ((uint32_t)b[3] << 24));
}

static inline void uvc_put_le_i32(uint8_t *b, int32_t v) {
    uint32_t u = (uint32_t)v;
    b[0] = (uint8_t)(u & 0xff);
    b[1] = (uint8_t)((u >> 8) & 0xff);
    b[2] = (uint8_t)((u >> 16) & 0xff);
    b[3] = (uint8_t)((u >> 24) & 0xff);
}

#endif

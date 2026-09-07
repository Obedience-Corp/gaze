#include "gaze.h"
#include "linux_cam.h"

#include <errno.h>
#include <stdio.h>
#include <time.h>
#include <jpeglib.h>
#include <linux/videodev2.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <unistd.h>

#define SNAP_MAX_W 1280
#define SNAP_JPEG_Q 65

struct mapbuf {
    void *start;
    size_t len;
};

static int clampi(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return v;
}

static int yuyv_to_jpeg(const uint8_t *yuyv, int w, int h, uint8_t **out, size_t *outn) {
    uint8_t *rgb = malloc((size_t)w * (size_t)h * 3);
    if (!rgb) {
        gaze_set_error("oom");
        return -1;
    }
    const uint8_t *s = yuyv;
    uint8_t *d = rgb;
    for (int i = 0; i < w * h; i += 2) {
        int y0 = s[0], u = s[1] - 128, y1 = s[2], v = s[3] - 128;
        s += 4;
        int r = y0 + (359 * v) / 256;
        int g = y0 - (88 * u) / 256 - (183 * v) / 256;
        int b = y0 + (454 * u) / 256;
        *d++ = (uint8_t)clampi(r);
        *d++ = (uint8_t)clampi(g);
        *d++ = (uint8_t)clampi(b);
        r = y1 + (359 * v) / 256;
        g = y1 - (88 * u) / 256 - (183 * v) / 256;
        b = y1 + (454 * u) / 256;
        *d++ = (uint8_t)clampi(r);
        *d++ = (uint8_t)clampi(g);
        *d++ = (uint8_t)clampi(b);
    }

    unsigned char *jpeg = NULL;
    unsigned long jlen = 0;
    struct jpeg_compress_struct cinfo;
    struct jpeg_error_mgr jerr;
    cinfo.err = jpeg_std_error(&jerr);
    jpeg_create_compress(&cinfo);
    jpeg_mem_dest(&cinfo, &jpeg, &jlen);
    cinfo.image_width = (JDIMENSION)w;
    cinfo.image_height = (JDIMENSION)h;
    cinfo.input_components = 3;
    cinfo.in_color_space = JCS_RGB;
    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, SNAP_JPEG_Q, TRUE);
    jpeg_start_compress(&cinfo, TRUE);
    while (cinfo.next_scanline < cinfo.image_height) {
        JSAMPROW row = rgb + (size_t)cinfo.next_scanline * (size_t)w * 3;
        jpeg_write_scanlines(&cinfo, &row, 1);
    }
    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    free(rgb);
    if (!jpeg || jlen < 800) {
        free(jpeg);
        gaze_set_error("jpeg encode failed");
        return -1;
    }
    *out = jpeg;
    *outn = (size_t)jlen;
    return 0;
}

static int pick_fmt(int fd, uint32_t *pix, uint32_t *w, uint32_t *h) {
    uint32_t want[] = {V4L2_PIX_FMT_MJPEG, V4L2_PIX_FMT_JPEG, V4L2_PIX_FMT_YUYV};
    uint32_t chosen = 0;
    for (unsigned wi = 0; wi < 3 && !chosen; wi++) {
        struct v4l2_fmtdesc d;
        for (unsigned i = 0;; i++) {
            memset(&d, 0, sizeof(d));
            d.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            d.index = i;
            if (ioctl(fd, VIDIOC_ENUM_FMT, &d) != 0) break;
            if (d.pixelformat == want[wi]) {
                chosen = d.pixelformat;
                break;
            }
        }
    }
    if (!chosen) {
        gaze_set_error("no MJPEG/YUYV capture format");
        return -1;
    }
    *pix = chosen;
    *w = SNAP_MAX_W;
    *h = 720;
    struct v4l2_frmsizeenum fs;
    uint32_t best_w = 0, best_h = 0;
    for (unsigned i = 0;; i++) {
        memset(&fs, 0, sizeof(fs));
        fs.index = i;
        fs.pixel_format = chosen;
        if (ioctl(fd, VIDIOC_ENUM_FRAMESIZES, &fs) != 0) break;
        uint32_t fw = 0, fh = 0;
        if (fs.type == V4L2_FRMSIZE_TYPE_DISCRETE) {
            fw = fs.discrete.width;
            fh = fs.discrete.height;
        } else if (fs.type == V4L2_FRMSIZE_TYPE_STEPWISE || fs.type == V4L2_FRMSIZE_TYPE_CONTINUOUS) {
            fw = fs.stepwise.max_width;
            if (fw > SNAP_MAX_W) fw = SNAP_MAX_W;
            fh = fs.stepwise.max_height * fw / (fs.stepwise.max_width ? fs.stepwise.max_width : 1);
        }
        if (fw <= SNAP_MAX_W && fw >= best_w) {
            best_w = fw;
            best_h = fh;
        }
    }
    if (best_w) {
        *w = best_w;
        *h = best_h;
    }
    return 0;
}

int gaze_snap(GazeCam *cam, uint8_t **jpeg, size_t *len) {
    if (!jpeg || !len) {
        gaze_set_error("bad args");
        return -1;
    }
    *jpeg = NULL;
    *len = 0;
    if (!cam) {
        gaze_set_error("no camera");
        return -1;
    }
    int fd = gaze_linux_video_fd(cam);
    if (fd < 0) {
        gaze_set_error("no video fd");
        return -1;
    }

    uint32_t pix = 0, w = 0, h = 0;
    if (pick_fmt(fd, &pix, &w, &h) != 0) return -1;

    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = w;
    fmt.fmt.pix.height = h;
    fmt.fmt.pix.pixelformat = pix;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (ioctl(fd, VIDIOC_S_FMT, &fmt) != 0) {
        gaze_set_errorf("VIDIOC_S_FMT failed", errno);
        return -1;
    }
    pix = fmt.fmt.pix.pixelformat;
    w = fmt.fmt.pix.width;
    h = fmt.fmt.pix.height;

    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count = 2;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (ioctl(fd, VIDIOC_REQBUFS, &req) != 0 || req.count < 1) {
        gaze_set_errorf("VIDIOC_REQBUFS failed", errno);
        return -1;
    }
    struct mapbuf maps[4];
    unsigned nmap = req.count;
    if (nmap > 4) nmap = 4;
    memset(maps, 0, sizeof(maps));
    for (unsigned i = 0; i < nmap; i++) {
        struct v4l2_buffer b;
        memset(&b, 0, sizeof(b));
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = i;
        if (ioctl(fd, VIDIOC_QUERYBUF, &b) != 0) {
            gaze_set_errorf("VIDIOC_QUERYBUF failed", errno);
            return -1;
        }
        maps[i].len = b.length;
        maps[i].start = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
        if (maps[i].start == MAP_FAILED) {
            gaze_set_error("mmap failed");
            return -1;
        }
        if (ioctl(fd, VIDIOC_QBUF, &b) != 0) {
            gaze_set_errorf("VIDIOC_QBUF failed", errno);
            return -1;
        }
    }

    enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (ioctl(fd, VIDIOC_STREAMON, &t) != 0) {
        gaze_set_errorf("VIDIOC_STREAMON failed", errno);
        goto fail;
    }

    struct v4l2_buffer b;
    memset(&b, 0, sizeof(b));
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b.memory = V4L2_MEMORY_MMAP;
    int got = 0;
    for (int attempt = 0; attempt < 40; attempt++) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval tv = {.tv_sec = 0, .tv_usec = 100000};
        int sel = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (sel <= 0) continue;
        if (ioctl(fd, VIDIOC_DQBUF, &b) != 0) continue;
        got = 1;
        break;
    }
    ioctl(fd, VIDIOC_STREAMOFF, &t);
    if (!got || b.index >= nmap || b.bytesused < 800) {
        gaze_set_error("camera produced no frame (grant video group, quit the vendor app)");
        goto fail;
    }

    const uint8_t *src = maps[b.index].start;
    size_t nbytes = b.bytesused;
    int rc = -1;
    if (pix == V4L2_PIX_FMT_MJPEG || pix == V4L2_PIX_FMT_JPEG) {
        uint8_t *buf = malloc(nbytes);
        if (!buf) {
            gaze_set_error("oom");
            goto fail;
        }
        memcpy(buf, src, nbytes);
        *jpeg = buf;
        *len = nbytes;
        rc = 0;
    } else if (pix == V4L2_PIX_FMT_YUYV) {
        rc = yuyv_to_jpeg(src, (int)w, (int)h, jpeg, len);
    } else {
        gaze_set_error("unsupported pixel format");
    }

    for (unsigned i = 0; i < nmap; i++)
        if (maps[i].start && maps[i].start != MAP_FAILED) munmap(maps[i].start, maps[i].len);
    req.count = 0;
    ioctl(fd, VIDIOC_REQBUFS, &req);
    return rc;

fail:
    for (unsigned i = 0; i < nmap; i++)
        if (maps[i].start && maps[i].start != MAP_FAILED) munmap(maps[i].start, maps[i].len);
    req.count = 0;
    ioctl(fd, VIDIOC_REQBUFS, &req);
    return -1;
}

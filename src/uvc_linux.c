#define _DEFAULT_SOURCE
#include "gaze.h"
#include "uvc_parse.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/uvcvideo.h>
#include <linux/videodev2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct GazeCam {
    int fd;
    char video[64];
    GazeInfo info;
};

static int cam_rank(const GazeInfo *i) {
    int r = 1;
    if (i->has_zoom) r += 2;
    if (i->has_pantilt) r += 4;
    return r;
}

static int read_hex16(const char *path, uint16_t *out) {
    FILE *f = fopen(path, "r");
    unsigned v = 0;
    if (!f) return -1;
    int n = fscanf(f, "%x", &v);
    fclose(f);
    if (n != 1) return -1;
    *out = (uint16_t)v;
    return 0;
}

static int read_text(const char *path, char *buf, size_t n) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    if (!fgets(buf, (int)n, f)) {
        fclose(f);
        return -1;
    }
    fclose(f);
    size_t L = strlen(buf);
    while (L && (buf[L - 1] == '\n' || buf[L - 1] == '\r')) buf[--L] = 0;
    return 0;
}

/* Walk from a sysfs node up until idVendor exists (USB device). */
static int usb_dir_from(const char *start, char *out, size_t n) {
    char cur[512];
    snprintf(cur, sizeof(cur), "%s", start);
    for (int hop = 0; hop < 12; hop++) {
        char idp[576];
        snprintf(idp, sizeof(idp), "%s/idVendor", cur);
        if (access(idp, R_OK) == 0) {
            snprintf(out, n, "%s", cur);
            return 0;
        }
        char parent[576];
        snprintf(parent, sizeof(parent), "%s/..", cur);
        char *rp = realpath(parent, NULL);
        if (!rp) return -1;
        snprintf(cur, sizeof(cur), "%s", rp);
        free(rp);
        if (strcmp(cur, "/") == 0) return -1;
    }
    return -1;
}

static int load_usb_info(const char *usbdir, GazeInfo *info) {
    char path[576];
    snprintf(path, sizeof(path), "%s/idVendor", usbdir);
    if (read_hex16(path, &info->vid) != 0) return -1;
    snprintf(path, sizeof(path), "%s/idProduct", usbdir);
    if (read_hex16(path, &info->pid) != 0) return -1;
    snprintf(path, sizeof(path), "%s/product", usbdir);
    if (read_text(path, info->name, sizeof(info->name)) != 0)
        snprintf(info->name, sizeof(info->name), "%04x:%04x", info->vid, info->pid);

    snprintf(path, sizeof(path), "%s/descriptors", usbdir);
    FILE *f = fopen(path, "rb");
    if (f) {
        uint8_t buf[4096];
        size_t n = fread(buf, 1, sizeof(buf), f);
        fclose(f);
        if (n >= 18) uvc_parse_config(buf, n, info);
    }
    return 0;
}

static int v4l_is_capture(int fd) {
    struct v4l2_capability cap;
    memset(&cap, 0, sizeof(cap));
    if (ioctl(fd, VIDIOC_QUERYCAP, &cap) != 0) return 0;
    unsigned caps = cap.capabilities;
    if (caps & V4L2_CAP_DEVICE_CAPS) caps = cap.device_caps;
    return (caps & V4L2_CAP_VIDEO_CAPTURE) ? 1 : 0;
}

static int v4l_has_fmt_ok(int fd) {
    struct v4l2_fmtdesc d;
    memset(&d, 0, sizeof(d));
    d.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    d.index = 0;
    return ioctl(fd, VIDIOC_ENUM_FMT, &d) == 0;
}

static int query_ctrl(int fd, uint32_t id, struct v4l2_queryctrl *q) {
    memset(q, 0, sizeof(*q));
    q->id = id;
    return ioctl(fd, VIDIOC_QUERYCTRL, q) == 0 && !(q->flags & V4L2_CTRL_FLAG_DISABLED);
}

static void fill_ctrl_flags(GazeCam *cam) {
    uint16_t zmin = 0, zmax = 0, zdef = 0;
    int32_t pmin = 0, pmax = 0, tmin = 0, tmax = 0;
    cam->info.has_zoom = (gaze_zoom_range(cam, &zmin, &zmax, &zdef) == 0 && zmax > zmin) ? 1 : 0;
    cam->info.has_pantilt =
        (gaze_pantilt_range(cam, &pmin, &pmax, &tmin, &tmax) == 0 && (pmax > pmin || tmax > tmin))
            ? 1
            : 0;
}

static int xu_query(GazeCam *cam, uint8_t req, uint8_t sel, uint8_t unit, void *data, uint16_t len) {
    struct uvc_xu_control_query q;
    memset(&q, 0, sizeof(q));
    q.unit = unit;
    q.selector = sel;
    q.query = req;
    q.size = len;
    q.data = data;
    if (ioctl(cam->fd, UVCIOC_CTRL_QUERY, &q) != 0) {
        gaze_set_errorf("UVCIOC_CTRL_QUERY failed", errno);
        return -1;
    }
    return 0;
}

static GazeCam *open_video(const char *devnode) {
    int fd = open(devnode, O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        gaze_set_error("open video node failed");
        return NULL;
    }
    if (!v4l_is_capture(fd) || !v4l_has_fmt_ok(fd)) {
        close(fd);
        return NULL;
    }
    char sys[256];
    snprintf(sys, sizeof(sys), "/sys/class/video4linux/%s/device", strrchr(devnode, '/') + 1);
    char real[512];
    if (!realpath(sys, real)) {
        close(fd);
        return NULL;
    }
    char usbdir[512];
    if (usb_dir_from(real, usbdir, sizeof(usbdir)) != 0) {
        close(fd);
        gaze_set_error("video node is not a USB camera");
        return NULL;
    }
    GazeCam *cam = calloc(1, sizeof(*cam));
    if (!cam) {
        close(fd);
        gaze_set_error("oom");
        return NULL;
    }
    cam->fd = fd;
    snprintf(cam->video, sizeof(cam->video), "%s", devnode);
    if (load_usb_info(usbdir, &cam->info) != 0) {
        close(fd);
        free(cam);
        gaze_set_error("usb sysfs");
        return NULL;
    }
    if (cam->info.xu_unit) {
        uint8_t lenb[2] = {0, 0};
        if (xu_query(cam, RC_GET_LEN, cam->info.xu_mode_sel, cam->info.xu_unit, lenb, 2) == 0)
            cam->info.xu_mode_len = (uint16_t)(lenb[0] | (lenb[1] << 8));
    }
    fill_ctrl_flags(cam);
    return cam;
}

static GazeCam *try_videoN(int n, uint16_t want_vid, uint16_t want_pid) {
    char path[64];
    snprintf(path, sizeof(path), "/dev/video%d", n);
    if (access(path, F_OK) != 0) return NULL;
    GazeCam *cam = open_video(path);
    if (!cam) return NULL;
    if ((want_vid || want_pid) && (cam->info.vid != want_vid || cam->info.pid != want_pid)) {
        gaze_close(cam);
        return NULL;
    }
    return cam;
}

int gaze_list(void) {
    uint32_t seen[64];
    int nseen = 0, n = 0;
    for (int i = 0; i < 64; i++) {
        GazeCam *cam = try_videoN(i, 0, 0);
        if (!cam) continue;
        uint32_t key = ((uint32_t)cam->info.vid << 16) | cam->info.pid;
        int dup = 0;
        for (int s = 0; s < nseen; s++)
            if (seen[s] == key) dup = 1;
        if (!dup && nseen < 64) seen[nseen++] = key;
        if (!dup) {
            printf("%04x:%04x  zoom=%u pantilt=%u  %s\n", cam->info.vid, cam->info.pid,
                   cam->info.has_zoom, cam->info.has_pantilt, cam->info.name);
            n++;
        }
        gaze_close(cam);
    }
    return n;
}

GazeCam *gaze_open(uint16_t vid, uint16_t pid) {
    gaze_set_error("");
    if (!vid && !pid) {
        const char *e = getenv("GAZE_DEV");
        if (e && e[0] && gaze_parse_devid(e, &vid, &pid) != 0) {
            gaze_set_error("GAZE_DEV must be vid:pid (hex)");
            return NULL;
        }
    }
    GazeCam *best = NULL;
    int best_rank = -1;
    for (int i = 0; i < 64; i++) {
        GazeCam *cam = try_videoN(i, vid, pid);
        if (!cam) continue;
        if (vid || pid) {
            if (best) gaze_close(best);
            best = cam;
            break;
        }
        int r = cam_rank(&cam->info);
        if (r > best_rank) {
            if (best) gaze_close(best);
            best = cam;
            best_rank = r;
        } else {
            gaze_close(cam);
        }
    }
    if (best) return best;
    gaze_set_error((vid || pid) ? "no matching UVC camera" : "no UVC camera");
    return NULL;
}

void gaze_close(GazeCam *cam) {
    if (!cam) return;
    if (cam->fd >= 0) close(cam->fd);
    free(cam);
}

int gaze_info(GazeCam *cam, GazeInfo *out) {
    if (!cam || !out) {
        gaze_set_error("bad args");
        return -1;
    }
    *out = cam->info;
    return 0;
}

static int g_ctrl(GazeCam *cam, uint32_t id, int32_t *v) {
    struct v4l2_control c = {.id = id};
    if (ioctl(cam->fd, VIDIOC_G_CTRL, &c) != 0) {
        gaze_set_errorf("VIDIOC_G_CTRL failed", errno);
        return -1;
    }
    *v = c.value;
    return 0;
}

static int s_ctrl(GazeCam *cam, uint32_t id, int32_t v) {
    struct v4l2_control c = {.id = id, .value = v};
    if (ioctl(cam->fd, VIDIOC_S_CTRL, &c) != 0) {
        gaze_set_errorf("VIDIOC_S_CTRL failed", errno);
        return -1;
    }
    return 0;
}

int gaze_get_zoom(GazeCam *cam, uint16_t *zoom) {
    int32_t v = 0;
    if (g_ctrl(cam, V4L2_CID_ZOOM_ABSOLUTE, &v) != 0) return -1;
    *zoom = (uint16_t)v;
    return 0;
}

int gaze_set_zoom(GazeCam *cam, uint16_t zoom) {
    if (s_ctrl(cam, V4L2_CID_ZOOM_ABSOLUTE, (int32_t)zoom) != 0) return -1;
    uint16_t got = 0;
    if (gaze_get_zoom(cam, &got) != 0) return -1;
    if (got != zoom) {
        gaze_set_error("zoom did not take");
        return -1;
    }
    return 0;
}

int gaze_zoom_range(GazeCam *cam, uint16_t *min, uint16_t *max, uint16_t *defv) {
    struct v4l2_queryctrl q;
    if (!query_ctrl(cam->fd, V4L2_CID_ZOOM_ABSOLUTE, &q)) {
        gaze_set_error("no zoom on this camera");
        return -1;
    }
    *min = (uint16_t)q.minimum;
    *max = (uint16_t)q.maximum;
    *defv = (uint16_t)q.default_value;
    return 0;
}

int gaze_get_pantilt(GazeCam *cam, int32_t *pan, int32_t *tilt) {
    if (g_ctrl(cam, V4L2_CID_PAN_ABSOLUTE, pan) != 0) return -1;
    if (g_ctrl(cam, V4L2_CID_TILT_ABSOLUTE, tilt) != 0) return -1;
    return 0;
}

int gaze_set_pantilt(GazeCam *cam, int32_t pan, int32_t tilt) {
    if (s_ctrl(cam, V4L2_CID_PAN_ABSOLUTE, pan) != 0) return -1;
    if (s_ctrl(cam, V4L2_CID_TILT_ABSOLUTE, tilt) != 0) return -1;
    int32_t gp = 0, gt = 0;
    if (gaze_get_pantilt(cam, &gp, &gt) != 0) return -1;
    if (gp != pan || gt != tilt) {
        usleep(200000);
        if (gaze_get_pantilt(cam, &gp, &gt) != 0) return -1;
    }
    if (gp != pan || gt != tilt) {
        gaze_set_error("pan/tilt did not take");
        return -1;
    }
    return 0;
}

int gaze_pantilt_range(GazeCam *cam, int32_t *pmin, int32_t *pmax, int32_t *tmin, int32_t *tmax) {
    struct v4l2_queryctrl p, t;
    if (!query_ctrl(cam->fd, V4L2_CID_PAN_ABSOLUTE, &p) ||
        !query_ctrl(cam->fd, V4L2_CID_TILT_ABSOLUTE, &t)) {
        gaze_set_error("no pan/tilt on this camera");
        return -1;
    }
    *pmin = p.minimum;
    *pmax = p.maximum;
    *tmin = t.minimum;
    *tmax = t.maximum;
    return 0;
}

int gaze_get_mode(GazeCam *cam, uint8_t *b0, uint8_t *b1) {
    if (!cam->info.xu_unit || cam->info.xu_mode_len < 2) {
        gaze_set_error("no vendor mode XU");
        return -1;
    }
    uint8_t buf[64];
    memset(buf, 0, sizeof(buf));
    uint16_t n = cam->info.xu_mode_len;
    if (n > sizeof(buf)) n = sizeof(buf);
    if (xu_query(cam, RC_GET_CUR, cam->info.xu_mode_sel, cam->info.xu_unit, buf, n) != 0)
        return -1;
    *b0 = buf[0];
    *b1 = buf[1];
    return 0;
}

int gaze_set_mode(GazeCam *cam, uint8_t b0, uint8_t b1) {
    if (!cam->info.xu_unit || cam->info.xu_mode_len < 2) {
        gaze_set_error("no vendor mode XU");
        return -1;
    }
    uint8_t buf[64];
    memset(buf, 0, sizeof(buf));
    uint16_t n = cam->info.xu_mode_len;
    if (n > sizeof(buf)) n = sizeof(buf);
    if (xu_query(cam, RC_GET_CUR, cam->info.xu_mode_sel, cam->info.xu_unit, buf, n) != 0)
        return -1;
    buf[0] = b0;
    buf[1] = b1;
    return xu_query(cam, RC_SET_CUR, cam->info.xu_mode_sel, cam->info.xu_unit, buf, n);
}

int gaze_linux_video_fd(GazeCam *cam) { return cam ? cam->fd : -1; }

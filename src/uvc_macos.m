#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOKit/IOCFPlugIn.h>
#include "gaze.h"
#include "uvc_parse.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct GazeCam {
    IOUSBDeviceInterface **dev;
    GazeInfo info;
};

static void set_err(const char *msg) { gaze_set_error(msg); }

static void set_errf(const char *fmt, IOReturn kr) { gaze_set_errorf(fmt, (int)kr); }

static IOReturn uvc_req(IOUSBDeviceInterface **dev, uint8_t bm, uint8_t bReq, uint8_t sel,
                        uint8_t unit, uint8_t iface, void *data, uint16_t len) {
    IOUSBDevRequest req;
    memset(&req, 0, sizeof(req));
    req.bmRequestType = bm;
    req.bRequest = bReq;
    req.wValue = (uint16_t)sel << 8;
    req.wIndex = ((uint16_t)unit << 8) | iface;
    req.wLength = len;
    req.pData = data;
    return (*dev)->DeviceRequest(dev, &req);
}

static int parse_uvc(IOUSBConfigurationDescriptorPtr cfg, GazeInfo *info) {
    uint16_t total = NSSwapLittleShortToHost(cfg->wTotalLength);
    return uvc_parse_config((const uint8_t *)cfg, total, info);
}

static void fill_name(io_service_t svc, uint16_t vid, uint16_t pid, char *name, size_t namelen) {
    CFTypeRef prop =
        IORegistryEntryCreateCFProperty(svc, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
    if (prop && CFGetTypeID(prop) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)prop, name, (CFIndex)namelen, kCFStringEncodingUTF8);
    } else {
        snprintf(name, namelen, "%04x:%04x", vid, pid);
    }
    if (prop) CFRelease(prop);
}

static GazeCam *try_service(io_service_t svc, uint16_t want_vid, uint16_t want_pid) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr || !plugin) return NULL;
    IOUSBDeviceInterface **dev = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plugin)->Release(plugin);
    if (!dev) return NULL;
    UInt16 vid = 0, pid = 0;
    (*dev)->GetDeviceVendor(dev, &vid);
    (*dev)->GetDeviceProduct(dev, &pid);
    if ((want_vid || want_pid) && (vid != want_vid || pid != want_pid)) {
        (*dev)->Release(dev);
        return NULL;
    }
    kr = (*dev)->USBDeviceOpen(dev);
    if (kr && kr != kIOReturnExclusiveAccess) {
        (*dev)->Release(dev);
        return NULL;
    }
    IOUSBConfigurationDescriptorPtr cfg = NULL;
    kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfg);
    if (kr || !cfg) {
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return NULL;
    }
    GazeInfo info;
    memset(&info, 0, sizeof(info));
    if (parse_uvc(cfg, &info) != 0) {
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return NULL;
    }
    GazeCam *cam = calloc(1, sizeof(*cam));
    if (!cam) {
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        set_err("oom");
        return NULL;
    }
    cam->dev = dev;
    cam->info = info;
    cam->info.vid = vid;
    cam->info.pid = pid;
    fill_name(svc, vid, pid, cam->info.name, sizeof(cam->info.name));
    if (cam->info.xu_unit) {
        uint8_t lenb[2] = {0, 0};
        if (uvc_req(cam->dev, 0xA1, RC_GET_LEN, cam->info.xu_mode_sel, cam->info.xu_unit,
                    cam->info.vc_iface, lenb, 2) == 0) {
            cam->info.xu_mode_len = (uint16_t)(lenb[0] | (lenb[1] << 8));
        }
    }
    {
        uint16_t zmin = 0, zmax = 0, zdef = 0;
        int32_t pmin = 0, pmax = 0, tmin = 0, tmax = 0;
        cam->info.has_zoom =
            (gaze_zoom_range(cam, &zmin, &zmax, &zdef) == 0 && zmax > zmin) ? 1 : 0;
        cam->info.has_pantilt =
            (gaze_pantilt_range(cam, &pmin, &pmax, &tmin, &tmax) == 0 &&
             (pmax > pmin || tmax > tmin))
                ? 1
                : 0;
    }
    return cam;
}

static int cam_rank(const GazeInfo *i) {
    int r = 1;
    if (i->has_zoom) r += 2;
    if (i->has_pantilt) r += 4;
    return r;
}

static io_iterator_t usb_iter(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) || !iter) {
        return 0;
    }
    return iter;
}

int gaze_list(void) {
    io_iterator_t iter = usb_iter();
    if (!iter) {
        set_err("no USB iterator");
        return -1;
    }
    int n = 0;
    io_service_t svc;
    while ((svc = IOIteratorNext(iter))) {
        GazeCam *cam = try_service(svc, 0, 0);
        IOObjectRelease(svc);
        if (!cam) continue;
        printf("%04x:%04x  zoom=%u pantilt=%u  %s\n", cam->info.vid, cam->info.pid,
               cam->info.has_zoom, cam->info.has_pantilt, cam->info.name);
        n++;
        gaze_close(cam);
    }
    IOObjectRelease(iter);
    return n;
}

GazeCam *gaze_open(uint16_t vid, uint16_t pid) {
    gaze_set_error("");
    if (!vid && !pid) {
        const char *e = getenv("GAZE_DEV");
        if (e && e[0] && gaze_parse_devid(e, &vid, &pid) != 0) {
            set_err("GAZE_DEV must be vid:pid (hex)");
            return NULL;
        }
    }
    io_iterator_t iter = usb_iter();
    if (!iter) {
        set_err("no USB iterator");
        return NULL;
    }
    GazeCam *best = NULL;
    int best_rank = -1;
    io_service_t svc;
    while ((svc = IOIteratorNext(iter))) {
        GazeCam *cam = try_service(svc, vid, pid);
        IOObjectRelease(svc);
        if (!cam) continue;
        if (vid || pid) {
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
    IOObjectRelease(iter);
    if (best) return best;
    set_err((vid || pid) ? "no matching UVC camera" : "no UVC camera");
    return NULL;
}

void gaze_close(GazeCam *cam) {
    if (!cam) return;
    if (cam->dev) {
        (*cam->dev)->USBDeviceClose(cam->dev);
        (*cam->dev)->Release(cam->dev);
    }
    free(cam);
}

int gaze_info(GazeCam *cam, GazeInfo *out) {
    if (!cam || !out) {
        set_err("bad args");
        return -1;
    }
    *out = cam->info;
    return 0;
}

static int uvc_get(GazeCam *cam, uint8_t sel, uint8_t unit, void *buf, uint16_t len) {
    IOReturn kr = uvc_req(cam->dev, 0xA1, RC_GET_CUR, sel, unit, cam->info.vc_iface, buf, len);
    if (kr) {
        set_errf("GET_CUR failed", kr);
        return -1;
    }
    return 0;
}

static int uvc_set(GazeCam *cam, uint8_t sel, uint8_t unit, void *buf, uint16_t len) {
    IOReturn kr = uvc_req(cam->dev, 0x21, RC_SET_CUR, sel, unit, cam->info.vc_iface, buf, len);
    if (kr) {
        set_errf("SET_CUR failed", kr);
        return -1;
    }
    return 0;
}

int gaze_get_zoom(GazeCam *cam, uint16_t *zoom) {
    uint8_t b[2] = {0};
    if (uvc_get(cam, CT_ZOOM_ABSOLUTE, cam->info.camera_unit, b, 2) != 0) return -1;
    *zoom = (uint16_t)(b[0] | (b[1] << 8));
    return 0;
}

int gaze_set_zoom(GazeCam *cam, uint16_t zoom) {
    uint8_t b[2] = {(uint8_t)(zoom & 0xff), (uint8_t)((zoom >> 8) & 0xff)};
    if (uvc_set(cam, CT_ZOOM_ABSOLUTE, cam->info.camera_unit, b, 2) != 0) return -1;
    uint16_t got = 0;
    if (gaze_get_zoom(cam, &got) != 0) return -1;
    if (got != zoom) {
        set_err("zoom did not take");
        return -1;
    }
    return 0;
}

int gaze_zoom_range(GazeCam *cam, uint16_t *min, uint16_t *max, uint16_t *defv) {
    uint8_t b[2];
    IOReturn kr;
    kr = uvc_req(cam->dev, 0xA1, RC_GET_MIN, CT_ZOOM_ABSOLUTE, cam->info.camera_unit,
                 cam->info.vc_iface, b, 2);
    if (kr) {
        set_errf("GET_MIN zoom failed", kr);
        return -1;
    }
    *min = (uint16_t)(b[0] | (b[1] << 8));
    kr = uvc_req(cam->dev, 0xA1, RC_GET_MAX, CT_ZOOM_ABSOLUTE, cam->info.camera_unit,
                 cam->info.vc_iface, b, 2);
    if (kr) {
        set_errf("GET_MAX zoom failed", kr);
        return -1;
    }
    *max = (uint16_t)(b[0] | (b[1] << 8));
    kr = uvc_req(cam->dev, 0xA1, RC_GET_DEF, CT_ZOOM_ABSOLUTE, cam->info.camera_unit,
                 cam->info.vc_iface, b, 2);
    if (kr) {
        set_errf("GET_DEF zoom failed", kr);
        return -1;
    }
    *defv = (uint16_t)(b[0] | (b[1] << 8));
    return 0;
}

int gaze_get_pantilt(GazeCam *cam, int32_t *pan, int32_t *tilt) {
    uint8_t b[8] = {0};
    if (uvc_get(cam, CT_PANTILT_ABSOLUTE, cam->info.camera_unit, b, 8) != 0) return -1;
    *pan = uvc_le_i32(b);
    *tilt = uvc_le_i32(b + 4);
    return 0;
}

int gaze_set_pantilt(GazeCam *cam, int32_t pan, int32_t tilt) {
    uint8_t b[8];
    uvc_put_le_i32(b, pan);
    uvc_put_le_i32(b + 4, tilt);
    if (uvc_set(cam, CT_PANTILT_ABSOLUTE, cam->info.camera_unit, b, 8) != 0) return -1;
    int32_t gp = 0, gt = 0;
    if (gaze_get_pantilt(cam, &gp, &gt) != 0) return -1;
    if (gp != pan || gt != tilt) {
        usleep(200000);
        if (gaze_get_pantilt(cam, &gp, &gt) != 0) return -1;
    }
    if (gp != pan || gt != tilt) {
        set_err("pan/tilt did not take");
        return -1;
    }
    return 0;
}

int gaze_pantilt_range(GazeCam *cam, int32_t *pmin, int32_t *pmax, int32_t *tmin, int32_t *tmax) {
    uint8_t b[8];
    IOReturn kr = uvc_req(cam->dev, 0xA1, RC_GET_MIN, CT_PANTILT_ABSOLUTE, cam->info.camera_unit,
                          cam->info.vc_iface, b, 8);
    if (kr) {
        set_errf("GET_MIN pantilt failed", kr);
        return -1;
    }
    *pmin = uvc_le_i32(b);
    *tmin = uvc_le_i32(b + 4);
    kr = uvc_req(cam->dev, 0xA1, RC_GET_MAX, CT_PANTILT_ABSOLUTE, cam->info.camera_unit,
                 cam->info.vc_iface, b, 8);
    if (kr) {
        set_errf("GET_MAX pantilt failed", kr);
        return -1;
    }
    *pmax = uvc_le_i32(b);
    *tmax = uvc_le_i32(b + 4);
    return 0;
}

int gaze_get_mode(GazeCam *cam, uint8_t *b0, uint8_t *b1) {
    if (!cam->info.xu_unit || cam->info.xu_mode_len < 2) {
        set_err("no vendor mode XU");
        return -1;
    }
    uint8_t buf[64];
    memset(buf, 0, sizeof(buf));
    uint16_t n = cam->info.xu_mode_len;
    if (n > sizeof(buf)) n = sizeof(buf);
    if (uvc_get(cam, cam->info.xu_mode_sel, cam->info.xu_unit, buf, n) != 0) return -1;
    *b0 = buf[0];
    *b1 = buf[1];
    return 0;
}

int gaze_set_mode(GazeCam *cam, uint8_t b0, uint8_t b1) {
    if (!cam->info.xu_unit || cam->info.xu_mode_len < 2) {
        set_err("no vendor mode XU");
        return -1;
    }
    uint8_t buf[64];
    memset(buf, 0, sizeof(buf));
    uint16_t n = cam->info.xu_mode_len;
    if (n > sizeof(buf)) n = sizeof(buf);
    if (uvc_get(cam, cam->info.xu_mode_sel, cam->info.xu_unit, buf, n) != 0) return -1;
    buf[0] = b0;
    buf[1] = b1;
    return uvc_set(cam, cam->info.xu_mode_sel, cam->info.xu_unit, buf, n);
}

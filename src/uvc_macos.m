#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOKit/IOCFPlugIn.h>
#include "gaze.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

struct GazeCam {
    IOUSBDeviceInterface **dev;
    GazeInfo info;
};

static char g_err[160];

const char *gaze_error(void) { return g_err; }

static void set_err(const char *msg) { snprintf(g_err, sizeof(g_err), "%s", msg); }

void gaze_set_error(const char *msg) { set_err(msg); }

static void set_errf(const char *fmt, IOReturn kr) {
    snprintf(g_err, sizeof(g_err), "%s (0x%x)", fmt, kr);
}

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
    uint8_t *p = (uint8_t *)cfg;
    uint8_t *end = p + total;
    uint8_t iface = 0xFF, cls = 0, sub = 0;
    info->vc_iface = 0xFF;
    info->camera_unit = 0xFF;
    info->xu_unit = 0;
    info->xu_mode_sel = 0;
    info->xu_mode_len = 0;
    while (p + 2 <= end) {
        uint8_t len = p[0];
        uint8_t typ = p[1];
        if (len < 2 || p + len > end) break;
        if (typ == 0x04 && len >= 9) {
            iface = p[2];
            cls = p[5];
            sub = p[6];
            if (cls == 14 && sub == 1) info->vc_iface = iface;
        }
        if (typ == CS_INTERFACE && cls == 14 && sub == 1 && len >= 8) {
            uint8_t st = p[2];
            if (st == VC_INPUT_TERMINAL) {
                uint16_t tt = (uint16_t)(p[4] | (p[5] << 8));
                if (tt == ITT_CAMERA) info->camera_unit = p[3];
            } else if (st == VC_EXTENSION_UNIT && len >= 24 && p[3] == UVC_XU_INSTA360) {
                info->xu_unit = p[3];
                info->xu_mode_sel = UVC_XU_MODE_SEL;
            }
        }
        p += len;
    }
    return (info->vc_iface != 0xFF && info->camera_unit != 0xFF) ? 0 : -1;
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
    return cam;
}

GazeCam *gaze_open(uint16_t vid, uint16_t pid) {
    g_err[0] = 0;
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) || !iter) {
        set_err("no USB iterator");
        return NULL;
    }
    GazeCam *found = NULL;
    GazeCam *fallback = NULL;
    io_service_t svc;
    while ((svc = IOIteratorNext(iter))) {
        GazeCam *cam = try_service(svc, vid, pid);
        IOObjectRelease(svc);
        if (!cam) continue;
        if (cam->info.vid == 0x2e1a) {
            if (fallback) gaze_close(fallback);
            found = cam;
            break;
        }
        if (!fallback) fallback = cam;
        else gaze_close(cam);
    }
    IOObjectRelease(iter);
    if (found) return found;
    if (fallback) return fallback;
    set_err("no UVC PTZ camera");
    return NULL;
}

void gaze_close(GazeCam *cam) {
    if (!cam) return;
    gaze_see_close();
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
    return uvc_set(cam, CT_ZOOM_ABSOLUTE, cam->info.camera_unit, b, 2);
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

static int32_t le_i32(const uint8_t *b) {
    return (int32_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) |
                     ((uint32_t)b[3] << 24));
}

static void put_le_i32(uint8_t *b, int32_t v) {
    uint32_t u = (uint32_t)v;
    b[0] = (uint8_t)(u & 0xff);
    b[1] = (uint8_t)((u >> 8) & 0xff);
    b[2] = (uint8_t)((u >> 16) & 0xff);
    b[3] = (uint8_t)((u >> 24) & 0xff);
}

int gaze_get_pantilt(GazeCam *cam, int32_t *pan, int32_t *tilt) {
    uint8_t b[8] = {0};
    if (uvc_get(cam, CT_PANTILT_ABSOLUTE, cam->info.camera_unit, b, 8) != 0) return -1;
    *pan = le_i32(b);
    *tilt = le_i32(b + 4);
    return 0;
}

int gaze_set_pantilt(GazeCam *cam, int32_t pan, int32_t tilt) {
    uint8_t b[8];
    put_le_i32(b, pan);
    put_le_i32(b + 4, tilt);
    return uvc_set(cam, CT_PANTILT_ABSOLUTE, cam->info.camera_unit, b, 8);
}

int gaze_pantilt_range(GazeCam *cam, int32_t *pmin, int32_t *pmax, int32_t *tmin, int32_t *tmax) {
    uint8_t b[8];
    IOReturn kr = uvc_req(cam->dev, 0xA1, RC_GET_MIN, CT_PANTILT_ABSOLUTE, cam->info.camera_unit,
                          cam->info.vc_iface, b, 8);
    if (kr) {
        set_errf("GET_MIN pantilt failed", kr);
        return -1;
    }
    *pmin = le_i32(b);
    *tmin = le_i32(b + 4);
    kr = uvc_req(cam->dev, 0xA1, RC_GET_MAX, CT_PANTILT_ABSOLUTE, cam->info.camera_unit,
                 cam->info.vc_iface, b, 8);
    if (kr) {
        set_errf("GET_MAX pantilt failed", kr);
        return -1;
    }
    *pmax = le_i32(b);
    *tmax = le_i32(b + 4);
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

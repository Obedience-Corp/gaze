#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "gaze.h"
#include <string.h>

#define SNAP_MAX_W 640.0
#define SNAP_JPEG_Q 0.65

@interface GazeSink : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (atomic, strong) NSData *jpeg;
@end

@implementation GazeSink
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sbuf
           fromConnection:(AVCaptureConnection *)conn {
    (void)output;
    (void)conn;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sbuf);
    if (!pb) return;
    CIImage *img = [CIImage imageWithCVPixelBuffer:pb];
    CGRect e = img.extent;
    if (e.size.width < 2 || e.size.height < 2) return;
    if (e.size.width > SNAP_MAX_W) {
        CGFloat sc = SNAP_MAX_W / e.size.width;
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(sc, sc)];
        e = img.extent;
    }
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext context];
    });
    CGImageRef cg = [ctx createCGImage:img fromRect:e];
    if (!cg) return;
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
    if (!dest) {
        CGImageRelease(cg);
        return;
    }
    NSDictionary *opts = @{
        (__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(SNAP_JPEG_Q)
    };
    CGImageDestinationAddImage(dest, cg, (__bridge CFDictionaryRef)opts);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(cg);
    if (ok && data.length > 800) self.jpeg = data;
}
@end

static AVCaptureSession *g_sess;
static GazeSink *g_sink;

static NSArray<AVCaptureDevice *> *video_devices(void) {
    NSArray *types = @[ AVCaptureDeviceTypeExternal, AVCaptureDeviceTypeBuiltInWideAngleCamera ];
    AVCaptureDeviceDiscoverySession *ds =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];
    return ds.devices;
}

static AVCaptureDevice *pick_device(const char *want) {
    NSArray<AVCaptureDevice *> *devs = video_devices();
    NSString *w = (want && want[0]) ? [NSString stringWithUTF8String:want] : nil;
    AVCaptureDevice *named = nil, *external = nil;
    for (AVCaptureDevice *d in devs) {
        if (w && [d.localizedName rangeOfString:w options:NSCaseInsensitiveSearch].location != NSNotFound) {
            named = d;
            break;
        }
        if (!external && d.position == AVCaptureDevicePositionUnspecified) external = d;
    }
    if (named) return named;
    if (external) return external;
    return devs.firstObject;
}

static int see_start(const char *want_name) {
    if (g_sess && g_sess.running) return 0;
    gaze_see_close();
    AVCaptureDevice *dev = pick_device(want_name);
    if (!dev) {
        gaze_set_error("no video device");
        return -1;
    }
    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
    if (!input) {
        gaze_set_error(err.localizedDescription.UTF8String ?: "camera input");
        return -1;
    }
    AVCaptureSession *sess = [[AVCaptureSession alloc] init];
    if ([sess canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
        sess.sessionPreset = AVCaptureSessionPreset1280x720;
    }
    if (![sess canAddInput:input]) {
        gaze_set_error("cannot add camera input");
        return -1;
    }
    [sess addInput:input];
    AVCaptureVideoDataOutput *out = [[AVCaptureVideoDataOutput alloc] init];
    out.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
    };
    out.alwaysDiscardsLateVideoFrames = YES;
    GazeSink *sink = [[GazeSink alloc] init];
    dispatch_queue_t q = dispatch_queue_create("gaze.see", DISPATCH_QUEUE_SERIAL);
    [out setSampleBufferDelegate:sink queue:q];
    if (![sess canAddOutput:out]) {
        gaze_set_error("cannot add camera output");
        return -1;
    }
    [sess addOutput:out];
    [sess startRunning];
    g_sess = sess;
    g_sink = sink;
    return 0;
}

void gaze_see_close(void) {
    if (g_sess) {
        [g_sess stopRunning];
        g_sess = nil;
    }
    g_sink = nil;
}

int gaze_snap(GazeCam *cam, uint8_t **jpeg, size_t *len) {
    if (!jpeg || !len) {
        gaze_set_error("bad args");
        return -1;
    }
    *jpeg = NULL;
    *len = 0;
    GazeInfo inf;
    memset(&inf, 0, sizeof(inf));
    if (cam) gaze_info(cam, &inf);
    if (see_start(inf.name) != 0) return -1;
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:3.0];
    NSData *data = nil;
    while ([until timeIntervalSinceNow] > 0) {
        data = g_sink.jpeg;
        if (data.length > 800) break;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (!data.length) {
        gaze_set_error("camera produced no frame (grant camera permission, quit the vendor app)");
        return -1;
    }
    uint8_t *buf = malloc(data.length);
    if (!buf) {
        gaze_set_error("oom");
        return -1;
    }
    memcpy(buf, data.bytes, data.length);
    *jpeg = buf;
    *len = data.length;
    return 0;
}

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
    if (self.jpeg.length > 800) return;
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
    CIContext *ctx = [CIContext context];
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

static int parse_model_vidpid(NSString *model, uint16_t *vid, uint16_t *pid) {
    if (!model) return -1;
    unsigned v = 0, p = 0;
    if (sscanf(model.UTF8String, "UVC Camera VendorID_%u ProductID_%u", &v, &p) != 2) return -1;
    *vid = (uint16_t)v;
    *pid = (uint16_t)p;
    return 0;
}

static AVCaptureDevice *device_for_vidpid(uint16_t vid, uint16_t pid) {
    NSArray *types = @[ AVCaptureDeviceTypeExternal, AVCaptureDeviceTypeBuiltInWideAngleCamera ];
    AVCaptureDeviceDiscoverySession *ds =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];
    for (AVCaptureDevice *d in ds.devices) {
        uint16_t v = 0, p = 0;
        if (parse_model_vidpid(d.modelID, &v, &p) != 0) continue;
        if (v == vid && p == pid) return d;
    }
    return nil;
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
    if (!cam || gaze_info(cam, &inf) != 0) {
        gaze_set_error("no camera");
        return -1;
    }
    AVCaptureDevice *dev = device_for_vidpid(inf.vid, inf.pid);
    if (!dev) {
        gaze_set_error("no AVFoundation device for this vid:pid");
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
    out.videoSettings =
        @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
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
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:3.0];
    NSData *data = nil;
    while ([until timeIntervalSinceNow] > 0) {
        data = sink.jpeg;
        if (data.length > 800) break;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    [sess stopRunning];
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

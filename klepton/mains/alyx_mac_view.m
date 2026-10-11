// Isolated macOS frontend. Reuses the upstream Metal compositor and pose seam.
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <pthread.h>
#include <math.h>
#include <time.h>
#include <dlfcn.h>
#include "kl_view_mtl.h"
#include "kl_ovrp.h"
#include "klepton.h"

extern void klvr_klepton_set_frame_pacer(void (*wait)(void));
extern int kl_alyx_psvr2_start(void);
extern void kl_alyx_psvr2_stop(void);
extern int kl_alyx_psvr2_alive(void);
static BOOL headset, showPreview;
static pthread_mutex_t pace_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pace_cv = PTHREAD_COND_INITIALIZER;
static unsigned long long published, consumed;
void kl_alyx_mac_pace_publish(void) {
    pthread_mutex_lock(&pace_mu); published++; pthread_cond_signal(&pace_cv);
    pthread_mutex_unlock(&pace_mu);
}
static void pace_wait(void) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec++;
    pthread_mutex_lock(&pace_mu);
    while (published == consumed)
        if (pthread_cond_timedwait(&pace_cv, &pace_mu, &deadline)) break;
    consumed = published;
    pthread_mutex_unlock(&pace_mu);
}
static struct {
    const char *game, *sysroot; int argc; char **argv;
    int (*run)(const char *, const char *, int, char **);
} guest;
static void *guest_main(void *unused) {
    (void)unused;
    kl_thread_init();
    int rc = guest.run(guest.game, guest.sysroot, guest.argc, guest.argv);
    fprintf(stderr, "[mac-view] guest returned %d\n", rc);
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp stop:nil]; });
    return NULL;
}

@interface AlyxView : NSView <NSWindowDelegate> {
    BOOL keys[128]; BOOL trigger, grip; float px, py, pz, yaw, pitch;
    CFTimeInterval previous, report;
    BOOL compositor;
}
- (void)tick:(NSTimer *)timer;
@end
@implementation AlyxView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES; self.layer = [CAMetalLayer layer];
        py = 1.6f; previous = CACurrentMediaTime(); report = previous;
    }
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) { [self.window close]; return; }
    if (event.keyCode < 128) keys[event.keyCode] = YES;
}
- (void)keyUp:(NSEvent *)event { if (event.keyCode < 128) keys[event.keyCode] = NO; }
- (void)mouseDown:(NSEvent *)event { (void)event; trigger = YES; }
- (void)mouseUp:(NSEvent *)event { (void)event; trigger = NO; }
- (void)rightMouseDown:(NSEvent *)event { (void)event; grip = YES; }
- (void)rightMouseUp:(NSEvent *)event { (void)event; grip = NO; }
- (void)mouseDragged:(NSEvent *)event {
    yaw -= event.deltaX * .0025f; pitch -= event.deltaY * .0025f;
    pitch = fmaxf(-1.5f, fminf(1.5f, pitch));
}
- (void)windowDidResignKey:(NSNotification *)note {
    (void)note; memset(keys, 0, sizeof keys); trigger = grip = NO;
}
- (void)windowWillClose:(NSNotification *)note { (void)note; [NSApp stop:nil]; }
- (void)tick:(NSTimer *)timer {
    (void)timer;
    if (headset && !kl_alyx_psvr2_alive()) {
        fprintf(stderr,"[mac-view] headset session ended; stopping game process\n");
        [NSApp stop:nil]; return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    float dt = fminf((float)(now - previous), .1f); previous = now;
    if (!headset) {
    float sy = sinf(yaw), cy = cosf(yaw);
    float forward = keys[13] - keys[1], right = keys[2] - keys[0]; // W S D A
    px += (-sy * forward + cy * right) * 2 * dt;
    pz += (-cy * forward - sy * right) * 2 * dt;
    py += (keys[15] - keys[3]) * 2 * dt; // R / F
    float sp = sinf(pitch/2), cp = cosf(pitch/2), s = sinf(yaw/2), c = cosf(yaw/2);
    float qx = c*sp, qy = cp*s, qz = -s*sp, qw = c*cp;
    kl_ovrp_set_head_pose_time(now);
    kl_ovrp_set_head_pose(px, py, pz, qx, qy, qz, qw);
    for (int hand = 0; hand < 2; hand++) {
        float x = hand ? .2f : -.2f, y = -.35f, z = -.35f;
        // Quaternion-vector rotation, matching the upstream viewer convention.
        float tx = 2*(qy*z-qz*y), ty = 2*(qz*x-qx*z), tz = 2*(qx*y-qy*x);
        kl_ovrp_set_hand_pose(hand, px+x+qw*tx+qy*tz-qz*ty,
            py+y+qw*ty+qz*tx-qx*tz, pz+z+qw*tz+qx*ty-qy*tx, qx,qy,qz,qw);
        unsigned buttons = hand ? (keys[49] ? 1u : 0u) : 0u; // Space => A
        if (hand && trigger) buttons |= 0x04000000;
        if (hand && grip) buttons |= 0x08000000;
        float sx = keys[124]-keys[123], stickY = keys[126]-keys[125];
        kl_ovrp_set_controller_input(hand, buttons, buttons,
            hand && trigger ? 1 : 0, hand && grip ? 1 : 0,
            hand ? sx : 0, hand ? stickY : 0);
    }
    }
    if (showPreview && !compositor) compositor = kl_viewmtl_start((__bridge void *)self.layer);
    if (compositor) {
        NSRect pixel = [self convertRectToBacking:self.bounds];
        kl_viewmtl_present((int)pixel.size.width, (int)pixel.size.height);
    }
    if (!headset) kl_alyx_mac_pace_publish();
    if (now-report > 5) {
        fprintf(stderr,"[mac-view] presented=%u guest=%llu lit=%lu\n",
            kl_viewmtl_frames(), kl_viewmtl_guest_frame(), kl_viewmtl_lit()); report=now;
    }
}
@end

int kl_alyx_mac_view(const char *game, const char *sysroot, int argc, char **argv,
    int (*run)(const char *, const char *, int, char **)) {
    @autoreleasepool {
        headset = getenv("KL_ALYX_PSVR2") != NULL;
        const char *preview = getenv("KL_ALYX_SHOW_PREVIEW");
        showPreview = !headset || (preview && !strcmp(preview,"1"));
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:showPreview ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory];
        // The guest's SDL surface is offscreen, as in the upstream headset app.
        // This frontend owns the visible Cocoa window.
        setenv("SDL_VIDEO_DRIVER","offscreen",1);
        const char *sdlPath = getenv("KL_SDL2_DYLIB");
        void *sdl = sdlPath ? dlopen(sdlPath, RTLD_NOW|RTLD_GLOBAL) : NULL;
        void (*ready)(void) = sdl ? dlsym(sdl,"SDL_SetMainReady") : NULL;
        int (*init)(unsigned) = sdl ? dlsym(sdl,"SDL_InitSubSystem") : NULL;
        const char *(*error)(void) = sdl ? dlsym(sdl,"SDL_GetError") : NULL;
        if (ready) ready();
        if (!init || init(0x20u)) {
            fprintf(stderr,"[mac-view] SDL video init failed: %s\n",error ? error() : "library unavailable");
            return 1;
        }
        // The OpenXR Metal client also loads the system Vulkan loader. Keep
        // SDL's offscreen WSI on the same direct MoltenVK instance as the guest,
        // rather than letting SDL discover a different global loader later.
        const char *mvkDir = getenv("KL_MVK_DIR");
        int (*loadVulkan)(const char *) = dlsym(sdl,"SDL_Vulkan_LoadLibrary");
        char mvkPath[2048];
        if (!mvkDir || !loadVulkan || snprintf(mvkPath,sizeof mvkPath,"%s/libMoltenVK.dylib",mvkDir) >= (int)sizeof mvkPath || loadVulkan(mvkPath) != 0) {
            fprintf(stderr,"[mac-view] SDL MoltenVK preload failed: %s\n",error ? error() : "library unavailable");
            return 1;
        }
        fprintf(stderr,"[mac-view] SDL Vulkan pinned to guest MoltenVK\n");
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1008,864)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        AlyxView *view = [[AlyxView alloc] initWithFrame:window.contentView.bounds];
        window.contentView=view; window.delegate=view;
        window.title=@"Alyx — Native Mac Preview";
        if (showPreview) {
            [window center]; [window makeKeyAndOrderFront:nil]; [window makeFirstResponder:view];
            [NSApp activateIgnoringOtherApps:YES];
        } else {
            [window orderOut:nil];
            fprintf(stderr,"[mac-view] headset mode: desktop preview hidden\n");
        }
        setenv("KLVR_HOST","0",1); setenv("KLVR_ASYNC_FRAMES","0",1);
        kl_ovrp_set_head_pose(0,1.6f,0,0,0,0,1);
        kl_ovrp_set_display_frequency(60); klvr_klepton_set_frame_pacer(pace_wait);
        if (headset && !kl_alyx_psvr2_start()) {
            fprintf(stderr,"[mac-view] headset session unavailable; game was not started\n");
            return 2;
        }
        guest.game=game; guest.sysroot=sysroot; guest.argc=argc; guest.argv=argv; guest.run=run;
        pthread_t thread;
        if (pthread_create(&thread,NULL,guest_main,NULL)) return 1;
        pthread_detach(thread);
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0/60 target:view
            selector:@selector(tick:) userInfo:nil repeats:YES];
        [NSApp run]; [timer invalidate]; kl_viewmtl_stop();
        if (headset) kl_alyx_psvr2_stop();
        return 0; // Process teardown ends this launcher's owned guest thread.
    }
}

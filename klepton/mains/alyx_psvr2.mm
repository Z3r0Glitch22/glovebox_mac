// Native OpenXR/Metal frontend for the existing PSVR2 runtime. No service or
// system runtime registration is changed here. The guest remains ARM64 native.
#define XR_USE_GRAPHICS_API_METAL
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <atomic>
#include <vector>
#include <string>
#include <thread>
#include <chrono>
#include <stdexcept>
#include <cmath>
#include <cstdio>
#include <cstring>
extern "C" {
#include "kl_ovrp.h"
#include "kl_glfb.h"
#include "kl_vulkan.h"
void kl_alyx_mac_pace_publish(void);
}

static void check(XrResult r,const char *call) {
    if (XR_FAILED(r)) throw std::runtime_error(std::string(call)+": "+std::to_string(r));
}
#define XR(call) check((call),#call)
static XrQuaternionf mul(XrQuaternionf a,XrQuaternionf b) {
    return {a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,
            a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
            a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w,
            a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z};
}
static XrQuaternionf inverse(XrQuaternionf q) { return {-q.x,-q.y,-q.z,q.w}; }
static XrVector3f rotate(XrQuaternionf q,XrVector3f p) {
    auto r=mul(mul(q,{p.x,p.y,p.z,0}),inverse(q)); return {r.x,r.y,r.z};
}
static XrPosef compose(XrPosef parent,XrPosef child) {
    auto p=rotate(parent.orientation,child.position);
    return {mul(parent.orientation,child.orientation),
            {parent.position.x+p.x,parent.position.y+p.y,parent.position.z+p.z}};
}
static XrPosef relative(XrPosef parent,XrPosef world) {
    XrPosef inv{inverse(parent.orientation),{0,0,0}};
    inv.position=rotate(inv.orientation,{-parent.position.x,-parent.position.y,-parent.position.z});
    return compose(inv,world);
}
static std::atomic<int> status{0}; // 0 connecting, 1 tracked views ready, -1 failure
static std::atomic<bool> stopping{false};
static std::thread worker;

class Presenter {
    XrInstance instance=XR_NULL_HANDLE;
    XrSystemId system=XR_NULL_SYSTEM_ID;
    XrSession session=XR_NULL_HANDLE;
    XrSpace origin=XR_NULL_HANDLE,head=XR_NULL_HANDLE,grip[2]{};
    XrActionSet actionSet=XR_NULL_HANDLE;
    XrAction pose{},trigger{},squeeze{},stick{},primary{},secondary{},click{},menu{},haptic{};
    XrPath hands[2]{};
    XrSessionState state=XR_SESSION_STATE_UNKNOWN;
    bool active=false;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    struct Eye { XrSwapchain chain{}; uint32_t w{},h{};
        std::vector<XrSwapchainImageMetalKHR> images; } eyes[2];
    XrPosef eyeLocal[2]{};
    uint64_t frames=0;
    float heightOffset=0; bool heightAnchored=false;
    XrPath path(const std::string &s) { XrPath p; XR(xrStringToPath(instance,s.c_str(),&p));return p; }
    XrAction action(XrActionType type,const char *name) {
        XrActionCreateInfo c{XR_TYPE_ACTION_CREATE_INFO};c.actionType=type;
        strcpy(c.actionName,name);strcpy(c.localizedActionName,name);
        c.countSubactionPaths=2;c.subactionPaths=hands;XrAction a;XR(xrCreateAction(actionSet,&c,&a));return a;
    }
    float scalar(XrAction a,int h) {
        XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO};get.action=a;get.subactionPath=hands[h];
        XrActionStateFloat v{XR_TYPE_ACTION_STATE_FLOAT};XR(xrGetActionStateFloat(session,&get,&v));
        return v.isActive?v.currentState:0;
    }
    bool button(XrAction a,int h) {
        XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO};get.action=a;get.subactionPath=hands[h];
        XrActionStateBoolean v{XR_TYPE_ACTION_STATE_BOOLEAN};XR(xrGetActionStateBoolean(session,&get,&v));
        return v.isActive&&v.currentState;
    }
public:
    ~Presenter() {
        for (auto &e:eyes) if(e.chain) xrDestroySwapchain(e.chain);
        for(auto g:grip) if(g) xrDestroySpace(g);
        if(head) xrDestroySpace(head);if(origin) xrDestroySpace(origin);
        if(active) xrEndSession(session);
        if(session) xrDestroySession(session);
        if(actionSet) xrDestroyActionSet(actionSet);
        if(instance) xrDestroyInstance(instance);
    }
    void initialize() {
        const char *extensions[]={XR_KHR_METAL_ENABLE_EXTENSION_NAME,XR_EXT_HP_MIXED_REALITY_CONTROLLER_EXTENSION_NAME};
        XrInstanceCreateInfo c{XR_TYPE_INSTANCE_CREATE_INFO};
        strcpy(c.applicationInfo.applicationName,"Alyx Native Mac PSVR2");c.applicationInfo.apiVersion=XR_MAKE_VERSION(1,0,0);
        c.enabledExtensionCount=2;c.enabledExtensionNames=extensions;XR(xrCreateInstance(&c,&instance));
        XrSystemGetInfo si{XR_TYPE_SYSTEM_GET_INFO};si.formFactor=XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;XR(xrGetSystem(instance,&si,&system));
        PFN_xrGetMetalGraphicsRequirementsKHR requirements;
        XR(xrGetInstanceProcAddr(instance,"xrGetMetalGraphicsRequirementsKHR",reinterpret_cast<PFN_xrVoidFunction*>(&requirements)));
        XrGraphicsRequirementsMetalKHR req{XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};XR(requirements(instance,system,&req));
        device=(__bridge id<MTLDevice>)req.metalDevice;queue=[device newCommandQueue];
        XrGraphicsBindingMetalKHR gb{XR_TYPE_GRAPHICS_BINDING_METAL_KHR};gb.commandQueue=(__bridge void*)queue;
        XrSessionCreateInfo sc{XR_TYPE_SESSION_CREATE_INFO};sc.next=&gb;sc.systemId=system;XR(xrCreateSession(instance,&sc,&session));
        uint32_t n=0;XR(xrEnumerateReferenceSpaces(session,0,&n,nullptr));std::vector<XrReferenceSpaceType> spaces(n);
        XR(xrEnumerateReferenceSpaces(session,n,&n,spaces.data()));
        XrReferenceSpaceCreateInfo sp{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};sp.poseInReferenceSpace.orientation.w=1;
        sp.referenceSpaceType=XR_REFERENCE_SPACE_TYPE_LOCAL;
        for(auto s:spaces) if(s==XR_REFERENCE_SPACE_TYPE_STAGE) sp.referenceSpaceType=s;
        fprintf(stderr,"[psvr2] origin=%s; existing runtime calibration retained\n",sp.referenceSpaceType==XR_REFERENCE_SPACE_TYPE_STAGE?"STAGE":"LOCAL");
        XR(xrCreateReferenceSpace(session,&sp,&origin));sp.referenceSpaceType=XR_REFERENCE_SPACE_TYPE_VIEW;XR(xrCreateReferenceSpace(session,&sp,&head));
        hands[0]=path("/user/hand/left");hands[1]=path("/user/hand/right");
        XrActionSetCreateInfo ac{XR_TYPE_ACTION_SET_CREATE_INFO};strcpy(ac.actionSetName,"alyx");strcpy(ac.localizedActionSetName,"Alyx controllers");
        XR(xrCreateActionSet(instance,&ac,&actionSet));
        pose=action(XR_ACTION_TYPE_POSE_INPUT,"grip_pose");trigger=action(XR_ACTION_TYPE_FLOAT_INPUT,"trigger");
        squeeze=action(XR_ACTION_TYPE_FLOAT_INPUT,"squeeze");stick=action(XR_ACTION_TYPE_VECTOR2F_INPUT,"stick");
        primary=action(XR_ACTION_TYPE_BOOLEAN_INPUT,"primary");secondary=action(XR_ACTION_TYPE_BOOLEAN_INPUT,"secondary");
        click=action(XR_ACTION_TYPE_BOOLEAN_INPUT,"stick_click");menu=action(XR_ACTION_TYPE_BOOLEAN_INPUT,"menu");
        haptic=action(XR_ACTION_TYPE_VIBRATION_OUTPUT,"haptic");
        std::vector<XrActionSuggestedBinding> bindings;
        for(int h=0;h<2;h++) {
            std::string base=h?"/user/hand/right":"/user/hand/left";
            for(auto b:std::vector<std::pair<XrAction,const char*>>{{pose,"/input/grip/pose"},{trigger,"/input/trigger/value"},
                {squeeze,"/input/squeeze/value"},{stick,"/input/thumbstick"},{primary,h?"/input/a/click":"/input/x/click"},
                {secondary,h?"/input/b/click":"/input/y/click"},{click,"/input/thumbstick/click"},{menu,"/input/menu/click"},{haptic,"/output/haptic"}})
                bindings.push_back({b.first,path(base+b.second)});
        }
        XrInteractionProfileSuggestedBinding sb{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
        sb.interactionProfile=path("/interaction_profiles/hp/mixed_reality_controller");sb.countSuggestedBindings=(uint32_t)bindings.size();sb.suggestedBindings=bindings.data();
        XR(xrSuggestInteractionProfileBindings(instance,&sb));
        XrSessionActionSetsAttachInfo attach{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};attach.countActionSets=1;attach.actionSets=&actionSet;XR(xrAttachSessionActionSets(session,&attach));
        for(int h=0;h<2;h++) { XrActionSpaceCreateInfo a{XR_TYPE_ACTION_SPACE_CREATE_INFO};a.action=pose;a.subactionPath=hands[h];a.poseInActionSpace.orientation.w=1;XR(xrCreateActionSpace(session,&a,&grip[h])); }
        XR(xrEnumerateViewConfigurationViews(instance,system,XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,0,&n,nullptr));
        if(n!=2) throw std::runtime_error("Expected two headset views");
        XrViewConfigurationView v[2]={{XR_TYPE_VIEW_CONFIGURATION_VIEW},{XR_TYPE_VIEW_CONFIGURATION_VIEW}};
        XR(xrEnumerateViewConfigurationViews(instance,system,XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,2,&n,v));
        XR(xrEnumerateSwapchainFormats(session,0,&n,nullptr));std::vector<int64_t> formats(n);XR(xrEnumerateSwapchainFormats(session,n,&n,formats.data()));
        int64_t format=MTLPixelFormatBGRA8Unorm_sRGB;bool supported=false;for(auto f:formats) if(f==format) supported=true;
        if(!supported) throw std::runtime_error("Runtime lacks the required BGRA8 sRGB swapchain");
        for(int e=0;e<2;e++) {
            eyes[e].w=v[e].recommendedImageRectWidth;eyes[e].h=v[e].recommendedImageRectHeight;
            XrSwapchainCreateInfo ci{XR_TYPE_SWAPCHAIN_CREATE_INFO};ci.usageFlags=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
            ci.format=format;ci.sampleCount=1;ci.width=eyes[e].w;ci.height=eyes[e].h;ci.faceCount=ci.arraySize=ci.mipCount=1;
            XR(xrCreateSwapchain(session,&ci,&eyes[e].chain));XR(xrEnumerateSwapchainImages(eyes[e].chain,0,&n,nullptr));
            eyes[e].images.resize(n,{XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR});
            XR(xrEnumerateSwapchainImages(eyes[e].chain,n,&n,(XrSwapchainImageBaseHeader*)eyes[e].images.data()));
        }
        kl_ovrp_set_eye_texture_size((int)eyes[0].w,(int)eyes[0].h);
        fprintf(stderr,"[psvr2] recommended eye=%ux%u; render override=%s\n",
                eyes[0].w,eyes[0].h,getenv("KLVR_EYE_SIZE") ?: "none");
        NSString *msl=@"#include <metal_stdlib>\nusing namespace metal; struct V{float4 p [[position]];float2 uv;}; vertex V vs(uint i [[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};V o;o.p=float4(p[i],0,1);o.uv=float2((p[i].x+1)*.5,(1-p[i].y)*.5);return o;} fragment float4 fs(V i [[stage_in]],texture2d_array<float> t [[texture(0)]],constant uint &slice [[buffer(0)]]){constexpr sampler s(filter::linear,address::clamp_to_edge);return float4(t.sample(s,i.uv,slice).rgb,1);}";
        NSError *err=nil;id<MTLLibrary> lib=[device newLibraryWithSource:msl options:nil error:&err];
        MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"vs"];pd.fragmentFunction=[lib newFunctionWithName:@"fs"];pd.colorAttachments[0].pixelFormat=(MTLPixelFormat)format;
        pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&err];
        if(!pipeline) throw std::runtime_error(err.localizedDescription.UTF8String ?: "Presenter shader compile failed");
    }
    void frame() {
        XrFrameWaitInfo wi{XR_TYPE_FRAME_WAIT_INFO};XrFrameState time{XR_TYPE_FRAME_STATE};XR(xrWaitFrame(session,&wi,&time));
        XrFrameBeginInfo bi{XR_TYPE_FRAME_BEGIN_INFO};XR(xrBeginFrame(session,&bi));
        XrSpaceLocation hp{XR_TYPE_SPACE_LOCATION};XR(xrLocateSpace(head,origin,time.predictedDisplayTime,&hp));
        XrView views[2]={{XR_TYPE_VIEW},{XR_TYPE_VIEW}};XrViewState vs{XR_TYPE_VIEW_STATE};uint32_t n=0;
        XrViewLocateInfo vi{XR_TYPE_VIEW_LOCATE_INFO};vi.viewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;vi.displayTime=time.predictedDisplayTime;vi.space=origin;
        XR(xrLocateViews(session,&vi,&vs,2,&n,views));
        bool valid=n==2&&(hp.locationFlags&XR_SPACE_LOCATION_POSITION_VALID_BIT)&&(hp.locationFlags&XR_SPACE_LOCATION_ORIENTATION_VALID_BIT)&&
            (vs.viewStateFlags&XR_VIEW_STATE_POSITION_VALID_BIT)&&(vs.viewStateFlags&XR_VIEW_STATE_ORIENTATION_VALID_BIT);
        if(valid) {
            auto p=hp.pose.position;auto q=hp.pose.orientation;
            // This runtime's stage is the SLAM origin, not a measured floor.
            // Place the first tracked eye at an explicit virtual standing height
            // in the game's world; apply the inverse mapping when submitting XR.
            if (!heightAnchored) {
                float height=1.6f; const char *e=getenv("KL_ALYX_EYE_HEIGHT_M");
                if (e) { char *end=nullptr; height=strtof(e,&end);
                    if (!end || *end || !std::isfinite(height) || height<.5f || height>2.3f)
                        throw std::runtime_error("KL_ALYX_EYE_HEIGHT_M must be 0.5 through 2.3 metres"); }
                heightOffset=height-p.y; heightAnchored=true;
                fprintf(stderr,"[psvr2] virtual eye height=%.3f m; origin offset=%.3f m (wear headset at launch)\n",height,heightOffset);
            }
            kl_ovrp_set_head_pose_time(CACurrentMediaTime());
            kl_ovrp_set_head_pose(p.x,p.y+heightOffset,p.z,q.x,q.y,q.z,q.w);
            for(int e=0;e<2;e++) { eyeLocal[e]=relative(hp.pose,views[e].pose);auto o=eyeLocal[e];auto f=views[e].fov;
                kl_ovrp_set_eye_offset(e,o.position.x,o.position.y,o.position.z);kl_ovrp_set_eye_rotation(e,o.orientation.x,o.orientation.y,o.orientation.z,o.orientation.w);
                kl_ovrp_set_eye_frustum(e,-tanf(f.angleLeft),tanf(f.angleRight),tanf(f.angleUp),-tanf(f.angleDown)); }
            if(time.predictedDisplayPeriod>0) kl_ovrp_set_display_frequency((float)(1e9/time.predictedDisplayPeriod));
            status.store(1,std::memory_order_release);
        }
        bool focused=state==XR_SESSION_STATE_FOCUSED;
        if(focused) { XrActiveActionSet set{actionSet,XR_NULL_PATH};XrActionsSyncInfo si{XR_TYPE_ACTIONS_SYNC_INFO};si.countActiveActionSets=1;si.activeActionSets=&set;XR(xrSyncActions(session,&si)); }
        for(int h=0;h<2;h++) {
            float tr=0,sq=0,sx=0,sy=0;unsigned buttons=0;
            if(focused) {
                XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO};get.action=pose;get.subactionPath=hands[h];XrActionStatePose ap{XR_TYPE_ACTION_STATE_POSE};XR(xrGetActionStatePose(session,&get,&ap));
                if(ap.isActive) { XrSpaceVelocity velocity{XR_TYPE_SPACE_VELOCITY}; XrSpaceLocation loc{XR_TYPE_SPACE_LOCATION}; loc.next=&velocity; XR(xrLocateSpace(grip[h],origin,time.predictedDisplayTime,&loc));
                    if((loc.locationFlags&XR_SPACE_LOCATION_POSITION_VALID_BIT)&&(loc.locationFlags&XR_SPACE_LOCATION_ORIENTATION_VALID_BIT)) {auto p=loc.pose.position;auto q=loc.pose.orientation;auto v=velocity.linearVelocity; auto av=velocity.angularVelocity;
                        if (!(velocity.velocityFlags&XR_SPACE_VELOCITY_LINEAR_VALID_BIT)) v={0,0,0};
                        if (!(velocity.velocityFlags&XR_SPACE_VELOCITY_ANGULAR_VALID_BIT)) av={0,0,0};
                        kl_ovrp_set_hand_motion(h,p.x,p.y+heightOffset,p.z,q.x,q.y,q.z,q.w,v.x,v.y,v.z,av.x,av.y,av.z);}
                    tr=scalar(trigger,h);sq=scalar(squeeze,h);get.action=stick;XrActionStateVector2f xy{XR_TYPE_ACTION_STATE_VECTOR2F};XR(xrGetActionStateVector2f(session,&get,&xy));if(xy.isActive){sx=xy.currentState.x;sy=xy.currentState.y;}
                    if(button(primary,h)) buttons|=h?0x1:0x100;if(button(secondary,h)) buttons|=h?0x2:0x200;
                    if(button(click,h)) buttons|=h?0x4:0x400;if(button(menu,h)) buttons|=0x100000;
                    if(tr>.5f) buttons|=h?0x4000000:0x10000000;if(sq>.5f) buttons|=h?0x8000000:0x20000000;
                }
            }
            kl_ovrp_set_controller_input(h,buttons,buttons,tr,sq,sx,sy);
            float amp=0,seconds=0;if(kl_ovrp_haptics_pull(h,&amp,&seconds)&&focused) {
                XrHapticActionInfo hi{XR_TYPE_HAPTIC_ACTION_INFO};hi.action=haptic;hi.subactionPath=hands[h];
                if(amp>0&&seconds>0) {XrHapticVibration hv{XR_TYPE_HAPTIC_VIBRATION};hv.amplitude=amp;hv.duration=(XrDuration)(fminf(seconds,.25f)*1e9);hv.frequency=XR_FREQUENCY_UNSPECIFIED;XR(xrApplyHapticFeedback(session,&hi,(XrHapticBaseHeader*)&hv));}
                else XR(xrStopHapticFeedback(session,&hi));
            }
        }
        kl_alyx_mac_pace_publish();
        int stage=kl_ovrp_last_complete_stage();kl_ovrp_render_pose rendered{};
        bool render=valid&&time.shouldRender&&kl_ovrp_stage_render_pose(stage,&rendered)&&rendered.complete&&kl_vulkan_frame_serial()>0;
        uint64_t now=(uint64_t)(CACurrentMediaTime()*1e9);
        if(rendered.submit_ns&&now>rendered.submit_ns+250000000ull) render=false;
        id<MTLTexture> sources[2];int slices[2]{};
        if(render) for(int e=0;e<2;e++) {sources[e]=(__bridge id<MTLTexture>)kl_glfb_eye_mtl_texture(e,stage,&slices[e]);if(!sources[e])render=false;}
        XrCompositionLayerProjectionView layers[2]={{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW},{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
        if(render) {
            XrPosef rh{{rendered.qx,rendered.qy,rendered.qz,rendered.qw},{rendered.px,rendered.py-heightOffset,rendered.pz}};
            for(int e=0;e<2;e++) {
                auto src=sources[e];if(src.device.registryID!=device.registryID) throw std::runtime_error("Game and headset use different Metal devices");
                if(src.textureType!=MTLTextureType2DArray) src=[src newTextureViewWithPixelFormat:src.pixelFormat textureType:MTLTextureType2DArray levels:NSMakeRange(0,1) slices:NSMakeRange(0,1)];
                if(!src) throw std::runtime_error("Eye texture cannot be sampled as an array view");
                uint32_t index;XrSwapchainImageAcquireInfo ai{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};XR(xrAcquireSwapchainImage(eyes[e].chain,&ai,&index));
                XrSwapchainImageWaitInfo wi2{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};wi2.timeout=XR_INFINITE_DURATION;XR(xrWaitSwapchainImage(eyes[e].chain,&wi2));
                id<MTLTexture> target=(__bridge id<MTLTexture>)eyes[e].images[index].texture;
                MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=target;rp.colorAttachments[0].loadAction=MTLLoadActionDontCare;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
                id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLRenderCommandEncoder> encoder=[cb renderCommandEncoderWithDescriptor:rp];
                [encoder setRenderPipelineState:pipeline];[encoder setFragmentTexture:src atIndex:0];uint32_t slice=(uint32_t)slices[e];[encoder setFragmentBytes:&slice length:sizeof slice atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[encoder endEncoding];[cb commit];[cb waitUntilCompleted];
                if(cb.status==MTLCommandBufferStatusError) throw std::runtime_error(cb.error.localizedDescription.UTF8String ?: "Metal headset copy failed");
                XrSwapchainImageReleaseInfo ri{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};XR(xrReleaseSwapchainImage(eyes[e].chain,&ri));
                layers[e].pose=compose(rh,eyeLocal[e]);auto t=rendered.tangents[e];layers[e].fov={-atanf(t[0]),atanf(t[1]),atanf(t[2]),-atanf(t[3])};
                layers[e].subImage.swapchain=eyes[e].chain;layers[e].subImage.imageRect={{0,0},{(int32_t)eyes[e].w,(int32_t)eyes[e].h}};
            }
            if(++frames%120==0) fprintf(stderr,"[psvr2] stereo frames submitted=%llu\n",(unsigned long long)frames);
        }
        XrCompositionLayerProjection projection{XR_TYPE_COMPOSITION_LAYER_PROJECTION};projection.space=origin;projection.viewCount=2;projection.views=layers;
        const XrCompositionLayerBaseHeader *list=(const XrCompositionLayerBaseHeader*)&projection;
        XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO};end.displayTime=time.predictedDisplayTime;end.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;end.layerCount=render?1:0;end.layers=render?&list:nullptr;XR(xrEndFrame(session,&end));
    }
    void run() {
        initialize();
        while(!stopping.load()) { @autoreleasepool {
            XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};XrResult r;
            while((r=xrPollEvent(instance,&event))==XR_SUCCESS) {
                if(event.type==XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                    state=((XrEventDataSessionStateChanged*)&event)->state;fprintf(stderr,"[psvr2] session state=%d\n",state);
                    if(state==XR_SESSION_STATE_READY&&!active){XrSessionBeginInfo bi{XR_TYPE_SESSION_BEGIN_INFO};bi.primaryViewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;XR(xrBeginSession(session,&bi));active=true;}
                    if(state==XR_SESSION_STATE_STOPPING){XR(xrEndSession(session));active=false;stopping=true;}
                    if(state==XR_SESSION_STATE_EXITING||state==XR_SESSION_STATE_LOSS_PENDING) stopping=true;
                }
                event={XR_TYPE_EVENT_DATA_BUFFER};
            }
            check(r,"xrPollEvent");if(active) frame();else std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }}
    }
};

extern "C" int kl_alyx_psvr2_start(void) {
    worker=std::thread([]{ @autoreleasepool {try { Presenter p;p.run(); }
        catch(const std::exception &e){fprintf(stderr,"[psvr2] %s\n",e.what());status=-1;stopping=true;}
        status=-1; stopping=true; kl_alyx_mac_pace_publish(); }});
    for(int i=0;i<1000&&status.load()==0;i++) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    if(status.load()!=1) {stopping=true;worker.detach();return 0;}
    return 1;
}
extern "C" int kl_alyx_psvr2_alive(void) { return status.load()==1 && !stopping.load(); }
extern "C" void kl_alyx_psvr2_stop(void) { stopping=true;if(worker.joinable())worker.detach(); }
extern "C" int kl_alyx_psvr2_pose_test(void) {
    // Round-trip a head/eye transform through arbitrary yaw and translation.
    XrPosef head{{0,sinf(.7f),0,cosf(.7f)},{1,1.6f,-2}};
    XrPosef eye{{0,0,sinf(.1f),cosf(.1f)},{-.032f,.01f,.02f}};
    auto world=compose(head,eye);auto recovered=relative(head,world);
    float error=fabsf(recovered.position.x-eye.position.x)+fabsf(recovered.position.y-eye.position.y)+fabsf(recovered.position.z-eye.position.z)
        +fabsf(recovered.orientation.x-eye.orientation.x)+fabsf(recovered.orientation.y-eye.orientation.y)+fabsf(recovered.orientation.z-eye.orientation.z)+fabsf(recovered.orientation.w-eye.orientation.w);
    XrPosef virtualHead=head; virtualHead.position.y+=1.73f;
    XrPosef restored=virtualHead; restored.position.y-=1.73f;
    auto submitted=compose(restored,eye);
    float heightError=fabsf(submitted.position.x-world.position.x)+fabsf(submitted.position.y-world.position.y)+fabsf(submitted.position.z-world.position.z);
    bool ok=error<1e-5f && heightError<1e-5f;
    fprintf(stderr,"PSVR2 pose composition round-trip: %s (error %.8f, height mapping %.8f)\n",ok?"PASS":"FAIL",error,heightError);return ok?0:1;
}

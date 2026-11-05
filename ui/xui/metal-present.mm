//
// xemu User Interface
//
// Native Metal presentation backend for the Vulkan renderer on Apple Silicon.
//
// See metal-present.h for the high-level description. Because Apple's OpenGL
// cannot share resources with Metal, both the emulator framebuffer and the Dear
// ImGui HUD are rendered on Metal and presented through a CAMetalLayer.
//
// NOTE: This code path is macOS-only and is currently UNVERIFIED (no macOS 26 /
// Apple Silicon / KosmicKrisp toolchain was available when it was written).
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//

#include "metal-present.h"

#ifdef __APPLE__

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <assert.h>
#include <math.h>
#include <string.h>
#include <float.h>

#include "common.hh"
#include <imgui_impl_metal.h>
#include "ui/xemu-widescreen.h"

//
// Metal Shading Language port of the GLSL gamma blit used by the OpenGL UI
// (see ui/xui/gl-helpers.cc: image_gamma_frag_src + the shared vertex shader).
//
static const char *kBlitMSLSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct BlitVertIn {
    float2 position;
    float2 texcoord;
};

struct BlitUniforms {
    float4 scaleOffset;      // xy = position scale, zw = position offset (NDC)
    float4 texScaleOffset;   // xy = texcoord scale, zw = texcoord offset
    int    flip;             // non-zero flips the texcoord V axis
};

struct BlitVSOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex BlitVSOut blit_vertex(const device BlitVertIn *verts [[buffer(0)]],
                             uint vid [[vertex_id]],
                             constant BlitUniforms &u [[buffer(1)]]) {
    BlitVertIn vin = verts[vid];
    BlitVSOut out;
    float2 t = vin.texcoord;
    if (u.flip != 0) {
        t.y = 1.0 - t.y;
    }
    out.texcoord = t * u.texScaleOffset.xy + u.texScaleOffset.zw;
    out.position = float4(vin.position * u.scaleOffset.xy + u.scaleOffset.zw,
                          0.0, 1.0);
    return out;
}

fragment float4 blit_gamma(BlitVSOut in [[stage_in]],
                           texture2d<float> tex [[texture(0)]],
                           sampler smp [[sampler(0)]],
                           constant uint *palette [[buffer(0)]]) {
    float4 col = tex.sample(smp, in.texcoord);
    // DAC palette LUT: palette[index] packs R,G,B into the low 24 bits, matching
    // the GLSL bitfieldExtract(palette[...], ch*8, 8) behaviour.
    uint pr = palette[uint(col.r * 255.0)] & 0xffu;
    uint pg = (palette[uint(col.g * 255.0)] >> 8) & 0xffu;
    uint pb = (palette[uint(col.b * 255.0)] >> 16) & 0xffu;
    return float4(float(pr) / 255.0, float(pg) / 255.0, float(pb) / 255.0, col.a);
}

// Plain passthrough blit used when the CPU-readback fallback provides a texture
// that has already had gamma applied.
fragment float4 blit_passthrough(BlitVSOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.texcoord);
}
)METAL";

// Matches BlitUniforms in the MSL source above. Padded to 48 bytes so the CPU
// layout matches Metal's float4-aligned struct size (the driver validates that
// the bound buffer is at least as large as the reflected struct).
struct BlitUniforms {
    float scaleOffset[4];
    float texScaleOffset[4];
    int32_t flip;
    int32_t pad[3];
};

// Matches BlitVertIn (interleaved, like the GL vertex buffer).
struct BlitVertIn {
    float position[2];
    float texcoord[2];
};

// Full-screen quad, matching the GL vertex data in gl-helpers.cc.
static const BlitVertIn kQuadVerts[4] = {
    //   x,     y,    s,   t
    { { -1.0f, -1.0f }, { 0.0f, 0.0f } }, // BL
    { { -1.0f,  1.0f }, { 0.0f, 1.0f } }, // TL
    { {  1.0f,  1.0f }, { 1.0f, 1.0f } }, // TR
    { {  1.0f, -1.0f }, { 1.0f, 0.0f } }, // BR
};

@interface XemuMetalPresenter : NSObject
// NOTE: Compiled WITH ARC. This file is Objective-C++ (.mm); the build enables
// -fobjc-arc for objcpp translation units (see meson.build), which reaches this
// root target as well as imgui's imgui_impl_metal.mm. `strong` properties own the
// long-lived Metal objects for the process lifetime; ARC releases them when the
// singleton is dropped during xemu_metal_present_cleanup(). The rest of xemu's
// Objective-C is .m / non-ARC and is left untouched.
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic, strong) id<MTLRenderPipelineState> gammaPipeline;
// Passthrough variant used by the screenshot capture path. The source
// framebuffer is sampled either way, so this pipeline must use the same
// color attachment format as the capture target (BGRA8Unorm).
@property (nonatomic, strong) id<MTLRenderPipelineState> passthroughPipeline;
@property (nonatomic, strong) id<MTLBuffer> vertexBuffer;
@property (nonatomic, strong) id<MTLBuffer> uniformBuffer;
@property (nonatomic, strong) id<MTLBuffer> paletteBuffer;
@property (nonatomic, strong) id<MTLSamplerState> samplerLinear;
@property (nonatomic, strong) id<MTLSamplerState> samplerNearest;

// A 1x1 texture used to stand in for HUD overlays that are still backed by
// OpenGL GLuint ids (icons, logo, snapshots). See xemu_metal_imgui_render_draw_data.
@property (nonatomic, strong) id<MTLTexture> dummyTexture;

// Per-frame state.
@property (nonatomic, strong) id<CAMetalDrawable> drawable;
@property (nonatomic, strong) id<MTLCommandBuffer> commandBuffer;
@property (nonatomic, strong) id<MTLRenderCommandEncoder> encoder;
@property (nonatomic, assign) CGSize drawableSize;

// Strong reference to the Vulkan renderer's exported framebuffer texture for
// the duration of the current UI frame. Without this, a guest resolution
// change on the render thread could destroy the backing VkImage (and release
// its MTLTexture) while our command buffer still samples it.
@property (nonatomic, strong) id<MTLTexture> framebufferTexture;

// Reverse-direction synchronization (Metal-read -> Vulkan-write). The shared
// framebuffer MTLTexture is written by the Vulkan renderer and read by our
// gamma blit. The next frame must not let Vulkan overwrite it until this
// frame's blit has finished reading it.
//
// We signal framebufferReadEvent on the GPU immediately after the blit draw
// (NOT after the HUD compositing / presentation), so the next frame's Vulkan
// render kickoff only waits for that read - letting the current frame's HUD
// and present overlap with the next frame's Vulkan rendering. This replaces a
// full waitUntilCompleted on the whole command buffer, which serialized all
// GPU work behind the CPU frame loop.
//
// framebufferReadSeq is the value encoded by the most recent blit's signal;
// framebufferReadWaited is the last value the CPU blocked on (so we never wait
// twice for the same frame, and skip the wait when a frame encoded no blit).
//
// TODO(PR4-followup): drive framebufferReadSeq into Vulkan (MTLSharedEvent
// imported via VK_EXT_metal_external_semaphore) so the wait moves fully onto
// the GPU and off the CPU timeline once the KosmicKrisp gate confirms support.
@property (nonatomic, strong) id<MTLSharedEvent> framebufferReadEvent;
@property (nonatomic, assign) uint64_t framebufferReadSeq;
@property (nonatomic, assign) uint64_t framebufferReadWaited;

// The command buffer of the most recently presented frame. Retained only so
// cleanup() can drain in-flight GPU work before our Metal objects (and the
// borrowed framebuffer texture reference) are released.
@property (nonatomic, strong) id<MTLCommandBuffer> lastCommandBuffer;
@end

static XemuMetalPresenter *g_metal = nil;
static bool g_metal_active = false;
static SDL_Window *g_metal_window = nil;
static bool g_pending_resize = false;
static int g_pending_width = 0;
static int g_pending_height = 0;

static float XemuMetalDisplayAspectRatio(int width, int height)
{
    switch (g_config.display.ui.aspect_ratio) {
    case CONFIG_DISPLAY_UI_ASPECT_RATIO_NATIVE:
        return (float)width / (float)height;
    case CONFIG_DISPLAY_UI_ASPECT_RATIO_16X9:
        return 16.0f / 9.0f;
    case CONFIG_DISPLAY_UI_ASPECT_RATIO_4X3:
        return 4.0f / 3.0f;
    case CONFIG_DISPLAY_UI_ASPECT_RATIO_AUTO:
    default:
        return xemu_get_widescreen() ? 16.0f / 9.0f : 4.0f / 3.0f;
    }
}

static id<MTLRenderPipelineState> BuildPipeline(id<MTLDevice> device,
                                                NSString *msl,
                                                NSString *fragName,
                                                NSError **error)
{
    id<MTLLibrary> library =
        [device newLibraryWithSource:msl options:nil error:error];
    if (library == nil) {
        fprintf(stderr, "XemuMetalPresenter: MSL compile failed: %s\n",
                [[*error localizedDescription] UTF8String]);
        return nil;
    }

    id<MTLFunction> vert = [library newFunctionWithName:@"blit_vertex"];
    id<MTLFunction> frag = [library newFunctionWithName:fragName];
    if (vert == nil || frag == nil) {
        fprintf(stderr, "XemuMetalPresenter: MSL function lookup failed\n");
        return nil;
    }

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vert;
    desc.fragmentFunction = frag;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    // The framebuffer texture is sampled into a float4 regardless of its source
    // format; the render target here is the CAMetalLayer drawable.
    return [device newRenderPipelineStateWithDescriptor:desc error:error];
}

static id<MTLSamplerState> MakeSampler(id<MTLDevice> device, MTLSamplerFilter filter)
{
    MTLSamplerDescriptor *s = [[MTLSamplerDescriptor alloc] init];
    s.minFilter = filter;
    s.magFilter = filter;
    s.sAddressMode = MTLSamplerAddressModeClampToEdge;
    s.tAddressMode = MTLSamplerAddressModeClampToEdge;
    s.lodMinClamp = 0.0f;
    s.lodMaxClamp = FLT_MAX;
    return [device newSamplerStateWithDescriptor:s];
}

static void ApplyLayerSize(XemuMetalPresenter *p, int width, int height)
{
    if (width <= 0 || height <= 0) {
        return;
    }

    const CGFloat scale = p.layer.contentsScale;
    CGSize drawableSize = CGSizeMake((CGFloat)width, (CGFloat)height);
    p.layer.drawableSize = drawableSize;
    p.drawableSize = drawableSize;
    (void)scale;
}

@implementation XemuMetalPresenter
@end

bool xemu_metal_present_init(SDL_Window *window)
{
    @autoreleasepool {
        if (g_metal_active) {
            return true;
        }

        NSView *view = (NSView *)SDL_GetPointerProperty(
            SDL_GetWindowProperties(window),
            SDL_PROP_WINDOW_COCOA_VIEW_POINTER, nullptr);
        if (view == nil) {
            fprintf(stderr, "xemu_metal_present_init: failed to get NSView\n");
            return false;
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            fprintf(stderr, "xemu_metal_present_init: no Metal device\n");
            return false;
        }

        // Sanity check: prefer the device the Vulkan renderer exported its
        // MTLTexture from. On single-GPU Apple Silicon these are the same object.
        void *vk_device = nv2a_get_mtl_device();
        if (vk_device != nullptr) {
            id<MTLDevice> exported = (__bridge id<MTLDevice>)vk_device;
            if (exported != device) {
                fprintf(stderr, "xemu_metal_present_init: warning - Vulkan MTLDevice "
                                "differs from system default device\n");
            }
        }

        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.contentsScale = view.window.backingScaleFactor;

        // Render the layer into the SDL view's hierarchy.
        view.wantsLayer = YES;
        view.layer = layer;

        XemuMetalPresenter *p = [[XemuMetalPresenter alloc] init];
        p.device = device;
        p.layer = layer;
        p.queue = [device newCommandQueue];

        int width = 0, height = 0;
        SDL_GetWindowSizeInPixels(window, &width, &height);
        p.layer.drawableSize = CGSizeMake(width, height);
        p.drawableSize = CGSizeMake(width, height);

        NSError *error = nil;
        p.gammaPipeline = BuildPipeline(device,
                                        [NSString stringWithUTF8String:kBlitMSLSource],
                                        @"blit_gamma", &error);
        if (p.gammaPipeline == nil) {
            fprintf(stderr, "xemu_metal_present_init: pipeline creation failed\n");
            return false;
        }

        p.passthroughPipeline = BuildPipeline(device,
                                              [NSString stringWithUTF8String:kBlitMSLSource],
                                              @"blit_passthrough", &error);
        if (p.passthroughPipeline == nil) {
            fprintf(stderr, "xemu_metal_present_init: passthrough pipeline creation failed\n");
            return false;
        }

        p.vertexBuffer = [device newBufferWithBytes:kQuadVerts
                                             length:sizeof(kQuadVerts)
                                            options:MTLResourceOptionCPUCacheModeDefault];
        p.uniformBuffer = [device newBufferWithLength:sizeof(BlitUniforms)
                                              options:MTLResourceOptionCPUCacheModeDefault];
        p.paletteBuffer = [device newBufferWithLength:sizeof(uint32_t) * 256
                                              options:MTLResourceOptionCPUCacheModeDefault];
        p.samplerLinear = MakeSampler(device, MTLSamplerFilterLinear);
        p.samplerNearest = MakeSampler(device, MTLSamplerFilterNearest);

        // 1x1 placeholder used to neutralize not-yet-ported GL-overlay textures.
        MTLTextureDescriptor *dummy_desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:1
                                        height:1
                                     mipmapped:NO];
        dummy_desc.usage = MTLTextureUsageShaderRead;
        p.dummyTexture = [device newTextureWithDescriptor:dummy_desc];

        // GPU-signaled event used for the Metal-read -> Vulkan-write reverse
        // dependency (see the framebufferReadEvent property comment).
        p.framebufferReadEvent = [device newSharedEvent];

        g_metal = p;
        g_metal_window = window;
        g_metal_active = true;
        return true;
    }
}

void xemu_metal_present_cleanup(void)
{
    @autoreleasepool {
        if (!g_metal_active) {
            return;
        }

        // Drain any in-flight Metal work before releasing our objects. The
        // command buffer may still reference the framebuffer MTLTexture that is
        // owned by the Vulkan renderer; waiting for completion guarantees the
        // renderer can safely finalize (destroy) the shared image afterward.
        if (g_metal.encoder != nil) {
            [g_metal.encoder endEncoding];
            g_metal.encoder = nil;
        }
        if (g_metal.commandBuffer != nil) {
            [g_metal.commandBuffer commit];
            g_metal.commandBuffer = nil;
        }
        if (g_metal.lastCommandBuffer != nil) {
            [g_metal.lastCommandBuffer waitUntilCompleted];
            g_metal.lastCommandBuffer = nil;
        }

        g_metal.drawable = nil;
        g_metal.framebufferTexture = nil;
        g_metal = nil;
        g_metal_active = false;
        g_metal_window = nil;
        g_pending_resize = false;
    }
}

bool xemu_metal_present_is_active(void)
{
    return g_metal_active;
}

void *xemu_metal_present_device(void)
{
    if (!g_metal_active) {
        return nullptr;
    }
    return (__bridge void *)g_metal.device;
}

void xemu_metal_present_resize(int width, int height)
{
    if (!g_metal_active) {
        return;
    }
    g_pending_resize = true;
    g_pending_width = width;
    g_pending_height = height;
}

void xemu_metal_present_size(int *width, int *height)
{
    if (width) {
        *width = (int)g_metal.drawableSize.width;
    }
    if (height) {
        *height = (int)g_metal.drawableSize.height;
    }
}

void xemu_metal_present_begin_frame(void)
{
    @autoreleasepool {
        assert(g_metal_active);

        // Reverse-direction synchronization: ensure the previous frame's Metal
        // blit has finished SAMPLING the shared framebuffer MTLTexture before
        // the caller lets the Vulkan renderer overwrite it (get_framebuffer ->
        // pgraph sync). We wait on the GPU-signaled event value rather than the
        // whole command buffer, so the previous frame's HUD compositing and
        // presentation overlap with this frame's Vulkan rendering. This is the
        // CPU/GPU-overlap analog of removing a glFinish() in the GL path.
        //
        // get_framebuffer() is only called after this returns, and the event is
        // signaled during the prior frame's blit (early in that frame), so in
        // the steady state this wait is already satisfied and returns at once.
        // The generous timeout is only a hang-safety valve (it must never
        // trigger); if it does we log and proceed rather than wedge the UI
        // thread, at the cost of at most a single-frame glitch.
        if (g_metal.framebufferReadSeq > g_metal.framebufferReadWaited) {
            BOOL signaled = [g_metal.framebufferReadEvent
                waitUntilSignaledValue:g_metal.framebufferReadSeq
                             timeoutMS:1000];
            if (!signaled) {
                fprintf(stderr, "xemu_metal_present_begin_frame: framebuffer "
                                "read event stalled (seq=%llu)\n",
                        (unsigned long long)g_metal.framebufferReadSeq);
            }
            g_metal.framebufferReadWaited = g_metal.framebufferReadSeq;
        }

        if (g_pending_resize) {
            ApplyLayerSize(g_metal, g_pending_width, g_pending_height);
            g_pending_resize = false;
        }

        id<CAMetalDrawable> drawable = [g_metal.layer nextDrawable];
        if (drawable == nil) {
            fprintf(stderr, "xemu_metal_present_begin_frame: no drawable\n");
            return;
        }
        g_metal.drawable = drawable;

        g_metal.commandBuffer = [g_metal.queue commandBuffer];
        if (g_metal.commandBuffer == nil) {
            fprintf(stderr, "xemu_metal_present_begin_frame: no command buffer\n");
            return;
        }

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

        g_metal.encoder = [g_metal.commandBuffer
            renderCommandEncoderWithDescriptor:pass];
    }
}

void xemu_metal_present_blit_framebuffer(void *mtl_texture_void, bool flip)
{
    @autoreleasepool {
        // Take a strong reference for the duration of the frame as soon as the
        // texture is handed over, even if we bail out below. This keeps the
        // MTLTexture alive if the render thread recreates the display image
        // (e.g. a guest resolution change) before our commands execute.
        g_metal.framebufferTexture = mtl_texture_void ? (__bridge id<MTLTexture>)mtl_texture_void : nil;

        if (!g_metal_active || g_metal.encoder == nil || g_metal.drawable == nil) {
            return;
        }

        id<MTLTexture> texture = g_metal.framebufferTexture;
        if (texture == nil) {
            return;
        }

        if (nv2a_get_screen_off()) {
            // Screen is blanked; leave the clear color showing.
            return;
        }

        const int tw = (int)texture.width;
        const int th = (int)texture.height;
        const int dw = (int)g_metal.drawableSize.width;
        const int dh = (int)g_metal.drawableSize.height;
        if (tw <= 0 || th <= 0 || dw <= 0 || dh <= 0) {
            return;
        }

        // Compute the fit/aspect scaling factors, mirroring the GL
        // RenderFramebuffer() logic in gl-helpers.cc.
        float sx = 1.0f, sy = 1.0f;
        if (g_config.display.ui.fit == CONFIG_DISPLAY_UI_FIT_STRETCH) {
            sx = 1.0f;
            sy = 1.0f;
        } else if (g_config.display.ui.fit == CONFIG_DISPLAY_UI_FIT_CENTER) {
            float t_ratio = XemuMetalDisplayAspectRatio(tw, th);
            sx = t_ratio * (float)th / (float)dw;
            sy = (float)th / (float)dh;
        } else {
            float t_ratio = XemuMetalDisplayAspectRatio(tw, th);
            float w_ratio = (float)dw / (float)dh;
            if (w_ratio >= t_ratio) {
                sx = t_ratio / w_ratio;
                sy = 1.0f;
            } else {
                sx = 1.0f;
                sy = w_ratio / t_ratio;
            }
        }

        // The framebuffer is rendered into a top-left origin drawable; Metal clip
        // space is bottom-left origin like GL, so the same V-flip semantics apply.
        BlitUniforms u;
        memset(&u, 0, sizeof(u));
        u.scaleOffset[0] = sx;
        u.scaleOffset[1] = sy;
        u.scaleOffset[2] = 0.0f;
        u.scaleOffset[3] = 0.0f;
        u.texScaleOffset[0] = 1.0f;
        u.texScaleOffset[1] = 1.0f;
        u.texScaleOffset[2] = 0.0f;
        u.texScaleOffset[3] = 0.0f;
        u.flip = flip ? 1 : 0;
        memcpy([g_metal.uniformBuffer contents], &u, sizeof(u));

        // Refresh the DAC palette LUT.
        const uint8_t *palette = nv2a_get_dac_palette();
        uint32_t *lut = (uint32_t *)[g_metal.paletteBuffer contents];
        for (int i = 0; i < 256; i++) {
            lut[i] = ((uint32_t)palette[i * 3 + 2] << 16) |
                     ((uint32_t)palette[i * 3 + 1] << 8) |
                     ((uint32_t)palette[i * 3]);
        }

        id<MTLRenderCommandEncoder> enc = g_metal.encoder;
        [enc setRenderPipelineState:g_metal.gammaPipeline];
        [enc setVertexBuffer:g_metal.vertexBuffer offset:0 atIndex:0];
        [enc setVertexBuffer:g_metal.uniformBuffer offset:0 atIndex:1];
        [enc setFragmentTexture:texture atIndex:0];
        [enc setFragmentBuffer:g_metal.paletteBuffer offset:0 atIndex:0];

        id<MTLSamplerState> sampler =
            (g_config.display.filtering == CONFIG_DISPLAY_FILTERING_NEAREST)
                ? g_metal.samplerNearest
                : g_metal.samplerLinear;
        [enc setFragmentSamplerState:sampler atIndex:0];

        MTLViewport viewport;
        viewport.originX = 0.0;
        viewport.originY = 0.0;
        viewport.width = (double)dw;
        viewport.height = (double)dh;
        viewport.zNear = 0.0;
        viewport.zFar = 1.0;
        [enc setViewport:viewport];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleFan
                vertexStart:0
                vertexCount:4];

        // Signal once the GPU has finished sampling the framebuffer for THIS
        // blit. It is encoded before the HUD draw commands (added later by
        // xemu_metal_imgui_render_draw_data into this same encoder), so the
        // next frame's begin_frame wait is satisfied as soon as the blit read
        // completes - the HUD and present are not on the critical path.
        g_metal.framebufferReadSeq++;
        [enc encodeSignalEvent:g_metal.framebufferReadEvent
                       atValue:g_metal.framebufferReadSeq];
    }
}

void xemu_metal_present_end_frame(bool vsync)
{
    @autoreleasepool {
        if (!g_metal_active) {
            return;
        }

        if (g_metal.encoder != nil) {
            [g_metal.encoder endEncoding];
            g_metal.encoder = nil;
        }

        id<CAMetalDrawable> drawable = g_metal.drawable;
        id<MTLCommandBuffer> cmdbuf = g_metal.commandBuffer;
        if (drawable != nil && cmdbuf != nil) {
            // vSync: CAMetalLayer throttles presentation to the display refresh
            // when displaySyncEnabled is YES. Disabling it lets frames present
            // without waiting for vblank (analog of SDL_GL_SetSwapInterval(0)).
            // NOTE: displaySyncEnabled is deprecated on recent macOS but remains
            // functional; revisit with CADisplayLink if precise control is needed.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            g_metal.layer.displaySyncEnabled = vsync;
#pragma clang diagnostic pop

            [drawable present];
            [cmdbuf commit];

            // Retain for the teardown drain in cleanup() only. Per-frame
            // framebuffer ordering is handled by framebufferReadEvent.
            g_metal.lastCommandBuffer = cmdbuf;
        }

        // The committed command buffer keeps its own references to textures
        // used by encoded commands, so our frame reference can go now.
        g_metal.framebufferTexture = nil;
        g_metal.drawable = nil;
        g_metal.commandBuffer = nil;
    }
}

//
// Screenshot capture.
//

bool xemu_metal_capture_framebuffer_rgba(void *mtl_texture_void, bool flip,
                                         std::vector<uint8_t> &rgba,
                                         int *out_width, int *out_height)
{
    @autoreleasepool {
        if (!g_metal_active) {
            return false;
        }

        id<MTLTexture> texture = (__bridge id<MTLTexture>)mtl_texture_void;
        if (texture == nil || nv2a_get_screen_off()) {
            // Nothing to capture (no framebuffer, or the screen is blanked).
            return false;
        }

        // Mirror the GL screenshot path (RenderFramebufferToPng): correct the
        // width to the display aspect ratio, then render 1:1 into an offscreen
        // target. The GL path reads back bottom-up and flips via !flip on
        // render; a fresh Metal texture read by getBytes() is top-down, so the
        // same !flip normalization applies directly.
        int width = (int)texture.height * XemuMetalDisplayAspectRatio((int)texture.width,
                                                                      (int)texture.height);
        int height = (int)texture.height;
        if (width <= 0 || height <= 0) {
            return false;
        }

        id<MTLTexture> target = nil;
        {
            MTLTextureDescriptor *desc = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                             width:width
                                            height:height
                                         mipmapped:NO];
            desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            target = [g_metal.device newTextureWithDescriptor:desc];
        }
        if (target == nil) {
            return false;
        }

        BlitUniforms u;
        memset(&u, 0, sizeof(u));
        u.scaleOffset[0] = 1.0f;
        u.scaleOffset[1] = 1.0f;
        u.texScaleOffset[0] = 1.0f;
        u.texScaleOffset[1] = 1.0f;
        u.flip = !flip;

        id<MTLBuffer> uniform = [g_metal.device
            newBufferWithBytes:&u
                        length:sizeof(u)
                       options:MTLResourceOptionCPUCacheModeDefault];

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer> cmdbuf = [g_metal.queue commandBuffer];
        id<MTLRenderCommandEncoder> enc =
            [cmdbuf renderCommandEncoderWithDescriptor:pass];
        if (enc == nil || uniform == nil) {
            return false;
        }

        [enc setRenderPipelineState:g_metal.passthroughPipeline];
        [enc setVertexBuffer:g_metal.vertexBuffer offset:0 atIndex:0];
        [enc setVertexBuffer:uniform offset:0 atIndex:1];
        [enc setFragmentTexture:texture atIndex:0];
        [enc setFragmentSamplerState:g_metal.samplerLinear atIndex:0];

        MTLViewport viewport;
        viewport.originX = 0.0;
        viewport.originY = 0.0;
        viewport.width = (double)width;
        viewport.height = (double)height;
        viewport.zNear = 0.0;
        viewport.zFar = 1.0;
        [enc setViewport:viewport];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleFan
                vertexStart:0
                vertexCount:4];
        [enc endEncoding];

        [cmdbuf commit];
        [cmdbuf waitUntilCompleted];

        // Copy out row by row (getBytes honors bytesPerRow padding), converting
        // the BGRA target to the tightly packed RGBA that the PNG encoder wants.
        const int bytes_per_row = (int)target.bytesPerRow;
        std::vector<uint8_t> packed((size_t)bytes_per_row * height);
        if (![target getBytes:&packed[0]
                   bytesPerRow:bytes_per_row
                     ofRegion:MTLRegionMake2D(0, 0, width, height)
                        mipmapLevel:0]) {
            return false;
        }

        rgba.resize((size_t)width * height * 4);
        for (int y = 0; y < height; y++) {
            const uint8_t *src = &packed[(size_t)y * bytes_per_row];
            uint8_t *dst = &rgba[(size_t)y * width * 4];
            for (int x = 0; x < width; x++) {
                dst[x * 4 + 0] = src[x * 4 + 2]; // R
                dst[x * 4 + 1] = src[x * 4 + 1]; // G
                dst[x * 4 + 2] = src[x * 4 + 0]; // B
                dst[x * 4 + 3] = 255;            // RGBA8 output is opaque
            }
        }

        if (out_width) {
            *out_width = width;
        }
        if (out_height) {
            *out_height = height;
        }
        return true;
    }
}

//
// Dear ImGui Metal backend wrappers.
//

void xemu_metal_imgui_init(void *mtl_device_void)
{
    @autoreleasepool {
        id<MTLDevice> device =
            g_metal_active ? g_metal.device : (__bridge id<MTLDevice>)mtl_device_void;
        if (device == nil) {
            fprintf(stderr, "xemu_metal_imgui_init: no Metal device\n");
            return;
        }
        // NOTE: xemu applies its own (custom) ImGui style after this returns,
        // so no style is set here.
        //
        // KNOWN GAP: The imgui Metal backend treats ImTextureID as an
        // id<MTLTexture>, but the HUD currently passes GLuint texture ids for
        // overlays (menu icons, controller masks, logo, snapshot thumbnails)
        // created by the OpenGL helpers in gl-helpers.cc. xemu_metal_imgui_render_draw_data
        // substitutes a placeholder so these render as a solid quad instead of
        // crashing; porting them to real Metal textures is the follow-up that
        // removes that substitution. Text HUD and the framebuffer are unaffected.
        ImGui_ImplMetal_Init(device);
    }
}

void xemu_metal_imgui_shutdown(void)
{
    if (!g_metal_active) {
        return;
    }
    ImGui_ImplMetal_Shutdown();
}

void xemu_metal_imgui_new_frame(void)
{
    @autoreleasepool {
        if (!g_metal_active || g_metal.drawable == nil) {
            return;
        }

        // ImGui_ImplMetal_NewFrame only consumes the drawable dimensions from
        // the pass descriptor; it reuses the encoder we already opened for the
        // framebuffer blit (so the HUD composites on top without a second pass).
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = g_metal.drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

        ImGui_ImplMetal_NewFrame(pass);
    }
}

void xemu_metal_imgui_render_draw_data(void *imgui_draw_data_void)
{
    @autoreleasepool {
        if (!g_metal_active || g_metal.encoder == nil) {
            return;
        }
        ImDrawData *drawData = (ImDrawData *)imgui_draw_data_void;

        // Defensive substitution: some HUD overlays still hand the backend a
        // OpenGL GLuint stored in an ImTextureID (see the known gap in
        // xemu_metal_imgui_init). The Metal backend messages ImTextureID as an
        // id<MTLTexture>, so a small integer would be treated as a bogus object
        // pointer and crash. Real ObjC object pointers on arm64 are always far
        // above the page-zero guard region, so any implausibly small value is
        // replaced with a 1x1 placeholder texture. This keeps the HUD rendering
        // (text + framebuffer) intact; porting the overlays to Metal is a
        // follow-up that simply restores their real textures here.
        if (g_metal.dummyTexture != nil) {
            for (int n = 0; n < drawData->CmdListsCount; n++) {
                ImDrawList *list = drawData->CmdLists[n];
                for (int i = 0; i < list->CmdBuffer.Size; i++) {
                    ImDrawCmd &cmd = list->CmdBuffer[i];
                    if ((uintptr_t)cmd.TextureId < 0x10000) {
                        cmd.TextureId =
                            (ImTextureID)(__bridge void *)g_metal.dummyTexture;
                    }
                }
            }
        }

        ImGui_ImplMetal_RenderDrawData(drawData, g_metal.commandBuffer,
                                       g_metal.encoder);
    }
}

void xemu_metal_imgui_recreate_font_texture(void)
{
    @autoreleasepool {
        if (!g_metal_active) {
            return;
        }
        ImGui_ImplMetal_DestroyFontsTexture();
        ImGui_ImplMetal_CreateFontsTexture(g_metal.device);
    }
}

#endif /* __APPLE__ */

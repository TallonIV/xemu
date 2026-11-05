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
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <assert.h>
#include <math.h>
#include <string.h>
#include <float.h>
#include <unordered_map>

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
@property (nonatomic, strong) id<MTLBuffer> vertexBuffer;
@property (nonatomic, strong) id<MTLBuffer> uniformBuffer;
@property (nonatomic, strong) id<MTLBuffer> paletteBuffer;
@property (nonatomic, strong) id<MTLSamplerState> samplerLinear;
@property (nonatomic, strong) id<MTLSamplerState> samplerNearest;

// A 1x1 transparent texture used as a fallback when a HUD overlay backed by an
// OpenGL GLuint id cannot be bridged into Metal (see XemuMetalBridgeGLTexture).
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

// Per-frame cache of Metal textures bridged from OpenGL HUD overlay textures.
// Keyed by the GLuint id the imgui HUD stores in ImTextureID. The overlay
// contents (controller masks, XMU, logo, icons, snapshot thumbnails) animate, so
// the pixel data is refreshed on every render pass, but the backing MTLTexture
// object is reused whenever the source dimensions are unchanged. Cleared in
// xemu_metal_present_cleanup().
struct XemuMetalGLTextureBridge {
    id<MTLTexture> texture;
    int width;
    int height;
};
static std::unordered_map<GLuint, XemuMetalGLTextureBridge> g_gl_tex_bridge;

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

static id<MTLSamplerState> MakeSampler(id<MTLDevice> device, MTLSamplerMinMagFilter filter)
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

        // SDL owns the NSWindow lifetime; borrow it with a __bridge cast (no
        // ARC ownership transfer).
        NSWindow *ns_window = (__bridge NSWindow *)SDL_GetPointerProperty(
            SDL_GetWindowProperties(window),
            SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, nullptr);
        if (ns_window == nil) {
            fprintf(stderr, "xemu_metal_present_init: failed to get NSWindow\n");
            return false;
        }

        // SDL3 only exposes the NSWindow (there is no COCOA_VIEW property); the
        // CAMetalLayer is hosted by the window's content view.
        NSView *view = [ns_window contentView];
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
        layer.contentsScale = ns_window.backingScaleFactor;
        // Synchronize presentation with CoreAnimation transactions so window
        // moves, live-resizes, and fullscreen transitions don't tear or show
        // garbage pixels. SDL3's own Metal view uses YES here; matches the
        // behavior of the Cocoa GL path.
        layer.presentsWithTransaction = YES;

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

        p.vertexBuffer = [device newBufferWithBytes:kQuadVerts
                                             length:sizeof(kQuadVerts)
                                            options:MTLResourceOptionCPUCacheModeDefault];
        p.uniformBuffer = [device newBufferWithLength:sizeof(BlitUniforms)
                                              options:MTLResourceOptionCPUCacheModeDefault];
        p.paletteBuffer = [device newBufferWithLength:sizeof(uint32_t) * 256
                                              options:MTLResourceOptionCPUCacheModeDefault];
        p.samplerLinear = MakeSampler(device, MTLSamplerMinMagFilterLinear);
        p.samplerNearest = MakeSampler(device, MTLSamplerMinMagFilterNearest);

        // 1x1 placeholder used to neutralize not-yet-ported GL-overlay textures.
        // Explicitly initialized to transparent black (0,0,0,0) so that any HUD
        // overlay quad sampling it fades to invisible under imgui's standard
        // premultiplied blend, rather than painting a solid black rectangle over
        // the framebuffer or leaking uninitialized bytes.
        MTLTextureDescriptor *dummy_desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:1
                                        height:1
                                     mipmapped:NO];
        dummy_desc.usage = MTLTextureUsageShaderRead;
        p.dummyTexture = [device newTextureWithDescriptor:dummy_desc];
        if (p.dummyTexture != nil) {
            const uint8_t transparent[4] = { 0, 0, 0, 0 };
            [p.dummyTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                              mipmapLevel:0
                                withBytes:transparent
                              bytesPerRow:4];
        }

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
        // Release any Metal textures bridged from OpenGL HUD overlays before the
        // device goes away (the MTLTexture objects are recreated on demand).
        g_gl_tex_bridge.clear();
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

        if (g_pending_resize) {
            ApplyLayerSize(g_metal, g_pending_width, g_pending_height);
            g_pending_resize = false;
        }

        // Acquire the drawable first. nextDrawable() blocks until a free
        // drawable is available (vsync pacing when displaySyncEnabled), and we
        // do not touch the shared framebuffer texture here, so the GPU is free
        // to finish the *previous* frame's blit while the CPU waits on vblank.
        id<CAMetalDrawable> drawable = [g_metal.layer nextDrawable];
        if (drawable == nil) {
            fprintf(stderr, "xemu_metal_present_begin_frame: no drawable\n");
            return;
        }
        g_metal.drawable = drawable;

        // Reverse-direction synchronization (single shared framebuffer image):
        // the caller invokes get_framebuffer() only AFTER this returns, and that
        // call lets the Vulkan renderer overwrite the framebuffer MTLTexture.
        // We must not proceed until the previous frame's Metal blit finished
        // SAMPLING it. Signalling happens during the prior blit (early in that
        // frame) and the nextDrawable() wait above has usually already let it
        // drain, so in the steady state (vsync on) this returns immediately
        // instead of serializing the CPU behind the GPU. This is the practical
        // analog of removing the GL path's glFinish().
        //
        // Full producer/consumer overlap with vsync DISABLED would additionally
        // require framebuffer depth in the renderer (a ring of exported
        // MTLTextures) or a Vulkan-side wait on this MTLSharedEvent imported as
        // an external semaphore. Both are intentionally deferred: the former
        // couples slot indices across the C/Metal boundary in a path we cannot
        // verify on target hardware, and the latter depends on driver support
        // the KosmicKrisp gate has not yet confirmed. See PR4-followup.
        //
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

        g_metal.commandBuffer = [g_metal.queue commandBuffer];
        if (g_metal.commandBuffer == nil) {
            fprintf(stderr, "xemu_metal_present_begin_frame: no command buffer\n");
            g_metal.drawable = nil;
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
        viewport.znear = 0.0;
        viewport.zfar = 1.0;
        [enc setViewport:viewport];
        // Metal has no triangle-fan primitive; the BL,TL,TR,BR quad above is
        // equivalent as a two-triangle strip (cull mode is left at its default
        // None, so winding does not affect coverage).
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];

        // Record the sequence value this frame's blit will publish. Signalling
        // framebufferReadEvent is done from the command buffer's completion
        // handler in end_frame: MTLRenderCommandEncoder has no
        // encodeSignalEvent:atValue: (only compute/blit encoders do), so it
        // cannot be emitted inline here.
        g_metal.framebufferReadSeq++;
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

            // Publish the framebuffer-read sequence once this frame's GPU work
            // has completed. MTLRenderCommandEncoder cannot encode an event
            // signal, so the reverse Vulkan-write sync is driven from the command
            // buffer completion handler. This waits on full frame completion
            // rather than just the blit read (slightly less overlap than the
            // intended design); revisit via VK_EXT_metal_external_semaphore once
            // target hardware can validate it (see framebufferReadEvent note).
            id<MTLSharedEvent> fb_event = g_metal.framebufferReadEvent;
            const uint64_t fb_seq = g_metal.framebufferReadSeq;
            [cmdbuf addCompletedHandler:^(id<MTLCommandBuffer> cb) {
                (void)cb;
                [fb_event setSignaledValue:fb_seq];
            }];

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
                                         int *out_width, int *out_height,
                                         int max_width, int max_height)
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
        // width to the display aspect ratio, optionally scale down to fit
        // (max_width x max_height) for snapshot thumbnails, then render into an
        // offscreen target using the same gamma/DAC-palette pipeline as the
        // display blit, so the PNG matches both what the user sees and what the
        // GL path produces. The GL path reads back bottom-up and flips via
        // !flip on render; a fresh Metal texture read by getBytes() is
        // top-down, so the same !flip normalization applies directly.
        int width = (int)texture.height * XemuMetalDisplayAspectRatio((int)texture.width,
                                                                      (int)texture.height);
        int height = (int)texture.height;
        if (width <= 0 || height <= 0) {
            return false;
        }

        if (max_width <= 0) {
            max_width = width;
        }
        if (max_height <= 0) {
            max_height = height;
        }
        {
            // Scale <width>x<height> proportionally into the max box, matching
            // ScaleDimensions() in gl-helpers.cc.
            const float w_ratio = (float)max_width / (float)max_height;
            const float t_ratio = (float)width / (float)height;
            int sw, sh;
            if (w_ratio >= t_ratio) {
                sw = (int)((float)max_width * t_ratio / w_ratio);
                sh = max_height;
            } else {
                sw = max_width;
                sh = (int)((float)max_height * w_ratio / t_ratio);
            }
            if (sw < 1) sw = 1;
            if (sh < 1) sh = 1;
            width = sw;
            height = sh;
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

        // Build a transient DAC palette LUT so this capture cannot race with the
        // in-flight on-screen blit that shares g_metal.paletteBuffer. Screenshot
        // parity with the GL path requires applying the same palette LUT.
        const uint8_t *pal = nv2a_get_dac_palette();
        uint32_t pal_lut[256];
        for (int i = 0; i < 256; i++) {
            pal_lut[i] = ((uint32_t)pal[i * 3 + 2] << 16) |
                         ((uint32_t)pal[i * 3 + 1] << 8) |
                         ((uint32_t)pal[i * 3]);
        }
        id<MTLBuffer> palette = [g_metal.device
            newBufferWithBytes:pal_lut
                        length:sizeof(pal_lut)
                       options:MTLResourceOptionCPUCacheModeDefault];

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer> cmdbuf = [g_metal.queue commandBuffer];
        id<MTLRenderCommandEncoder> enc =
            [cmdbuf renderCommandEncoderWithDescriptor:pass];
        if (enc == nil || uniform == nil || palette == nil) {
            return false;
        }

        [enc setRenderPipelineState:g_metal.gammaPipeline];
        [enc setVertexBuffer:g_metal.vertexBuffer offset:0 atIndex:0];
        [enc setVertexBuffer:uniform offset:0 atIndex:1];
        [enc setFragmentTexture:texture atIndex:0];
        [enc setFragmentBuffer:palette offset:0 atIndex:0];
        [enc setFragmentSamplerState:g_metal.samplerLinear atIndex:0];

        MTLViewport viewport;
        viewport.originX = 0.0;
        viewport.originY = 0.0;
        viewport.width = (double)width;
        viewport.height = (double)height;
        viewport.znear = 0.0;
        viewport.zfar = 1.0;
        [enc setViewport:viewport];
        // Metal has no triangle-fan primitive; see the presenter path above.
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
        [enc endEncoding];

        [cmdbuf commit];
        [cmdbuf waitUntilCompleted];

        // Copy out row by row, converting the BGRA target to the tightly packed
        // RGBA that the PNG encoder wants. MTLTexture exposes no bytesPerRow
        // property and getBytes returns void, so request a tightly packed BGRA8
        // row (width * 4) and read through it manually.
        const NSUInteger bytes_per_row = (NSUInteger)width * 4;
        std::vector<uint8_t> packed((size_t)bytes_per_row * height);
        [target getBytes:packed.data()
             bytesPerRow:bytes_per_row
           textureRange:MTLRegionMake2D(0, 0, width, height)
            mipmapLevel:0];

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
        // The imgui Metal backend treats ImTextureID as an id<MTLTexture>, while
        // the HUD passes OpenGL GLuint ids for its overlays (menu icons,
        // controller masks, XMU, logo, snapshot thumbnails) created by the OpenGL
        // helpers in gl-helpers.cc. Those helpers still run against the GL context
        // that remains current on this thread, so their FBO textures are live even
        // while presenting via Metal. xemu_metal_imgui_render_draw_data bridges
        // each such GLuint into a cached Metal texture (glGetTexImage readback ->
        // MTLTexture) so the overlays render correctly; a transparent 1x1 dummy is
        // used only when a texture cannot be read back. Text HUD and the
        // framebuffer are unaffected.
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

// Reads the level-0 image of a currently-live OpenGL texture and uploads it into
// a cached RGBA8 id<MTLTexture> usable by the imgui Metal backend. The GL
// context is current on this thread (made current in display_early_init and
// never unbound on the Metal path), so the direct-GL overlay FBO draws have
// already populated the source texture this frame. Returns nil when the id is
// not a live 2D texture with a level-0 image, letting the caller fall back to the
// dummy. GL state (2D binding, pack alignment) is saved and restored.
static id<MTLTexture> XemuMetalBridgeGLTexture(GLuint gl_tex, id<MTLDevice> device)
{
    GLint saved_binding = 0;
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &saved_binding);

    glBindTexture(GL_TEXTURE_2D, gl_tex);

    GLint width = 0, height = 0;
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &width);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &height);
    if (width <= 0 || height <= 0) {
        glBindTexture(GL_TEXTURE_2D, (GLuint)saved_binding);
        return nil;
    }

    auto it = g_gl_tex_bridge.find(gl_tex);
    if (it == g_gl_tex_bridge.end() || it->second.texture == nil ||
        it->second.width != (int)width || it->second.height != (int)height) {
        if (it != g_gl_tex_bridge.end()) {
            g_gl_tex_bridge.erase(it);
        }
        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:(NSUInteger)width
                                        height:(NSUInteger)height
                                     mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
        if (tex == nil) {
            glBindTexture(GL_TEXTURE_2D, (GLuint)saved_binding);
            return nil;
        }
        // Default-insert the entry (ARC zero-initializes the ObjC pointer
        // member), then populate it; avoids relying on aggregate
        // initialization of a struct that holds a __strong id.
        XemuMetalGLTextureBridge &entry = g_gl_tex_bridge[gl_tex];
        entry.texture = tex;
        entry.width = (int)width;
        entry.height = (int)height;
        it = g_gl_tex_bridge.find(gl_tex);
    }

    // Read back tightly packed RGBA8 and upload. glGetTexImage returns the image
    // with its first row at t=0; the imgui Metal backend samples v=0 from that
    // same row 0, so a direct (unflipped) copy reproduces the OpenGL path's
    // orientation for identical imgui draw data.
    const size_t bytes_per_row = (size_t)width * 4;
    std::vector<uint8_t> pixels(bytes_per_row * (size_t)height);

    GLint saved_align = 4;
    glGetIntegerv(GL_PACK_ALIGNMENT, &saved_align);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    glPixelStorei(GL_PACK_ALIGNMENT, saved_align);

    [it->second.texture
        replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
          mipmapLevel:0
            withBytes:pixels.data()
          bytesPerRow:(NSUInteger)bytes_per_row];

    glBindTexture(GL_TEXTURE_2D, (GLuint)saved_binding);
    return it->second.texture;
}

void xemu_metal_imgui_render_draw_data(void *imgui_draw_data_void)
{
    @autoreleasepool {
        if (!g_metal_active || g_metal.encoder == nil) {
            return;
        }
        ImDrawData *drawData = (ImDrawData *)imgui_draw_data_void;

        // The HUD still hands the Metal backend OpenGL GLuint texture ids for its
        // overlays (menu icons, controller masks, XMU, logo, snapshot thumbnails),
        // because those are drawn into FBOs by the OpenGL helpers in
        // gl-helpers.cc, which remain live on the still-current GL context. Bridge
        // each implausibly small ImTextureID (a GLuint; real ObjC object pointers
        // such as the imgui font atlas sit far above the page-zero guard region on
        // arm64 and are left untouched) into a cached Metal texture via readback.
        // Textures that cannot be read back fall back to the transparent dummy.
        id<MTLDevice> device = g_metal.device;
        for (int n = 0; n < drawData->CmdListsCount; n++) {
            ImDrawList *list = drawData->CmdLists[n];
            for (int i = 0; i < list->CmdBuffer.Size; i++) {
                ImDrawCmd &cmd = list->CmdBuffer[i];
                const uintptr_t tex_id = (uintptr_t)cmd.TextureId;
                if (tex_id == 0 || tex_id >= 0x10000) {
                    continue;
                }
                id<MTLTexture> bridged =
                    XemuMetalBridgeGLTexture((GLuint)tex_id, device);
                if (bridged == nil) {
                    bridged = g_metal.dummyTexture;
                }
                if (bridged != nil) {
                    cmd.TextureId = (ImTextureID)(__bridge void *)bridged;
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

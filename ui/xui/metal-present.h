//
// xemu User Interface
//
// Native Metal presentation backend for the Vulkan renderer on Apple Silicon.
//
// This mirrors the interface of win32-dxgi-present but, because Apple's OpenGL
// cannot share resources with Metal, it renders BOTH the emulator framebuffer
// and the Dear ImGui HUD entirely on Metal and presents via a CAMetalLayer.
//
// NOTE: This code path is macOS-only and is currently UNVERIFIED (no macOS
// 26 / Apple Silicon / KosmicKrisp toolchain was available when it was written).
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//

#ifndef XEMU_METAL_PRESENT_H
#define XEMU_METAL_PRESENT_H

#include <SDL3/SDL.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __APPLE__

#ifdef __cplusplus
extern "C" {
#endif

/* Initialize the Metal presenter and CAMetalLayer on the given SDL window.
 * Returns true on success. Must be called before the ImGui HUD is initialized. */
bool xemu_metal_present_init(SDL_Window *window);

/* Tear down all Metal resources. */
void xemu_metal_present_cleanup(void);

/* True if the Metal presentation path has taken over the window. */
bool xemu_metal_present_is_active(void);

/* Notify the presenter that the window size (in pixels) changed. The actual
 * drawable recreation happens on the next begin_frame. */
void xemu_metal_present_resize(int width, int height);

/* Begin a frame: acquires a drawable and creates a command buffer / render
 * encoder / render pass descriptor. Call before the ImGui new-frame. */
void xemu_metal_present_begin_frame(void);

/* Draw the emulator framebuffer (an id<MTLTexture>, passed as void*) into the
 * current drawable using the DAC-palette gamma blit pipeline. Call after
 * begin_frame and before the ImGui render step so the HUD composites on top. */
void xemu_metal_present_blit_framebuffer(void *mtl_texture, bool flip);

/* End the frame: finishes the render encoder, submits and presents. */
void xemu_metal_present_end_frame(bool vsync);

/* Current drawable size in pixels. */
void xemu_metal_present_size(int *width, int *height);

/* --- Dear ImGui Metal backend wrappers (kept here because the imgui Metal
 *     API uses Objective-C types that cannot be referenced from .cc files). --- */

/* Initialize the SDL3 platform backend (for Metal) and the Metal renderer
 * backend. 'mtl_device' is an id<MTLDevice> passed as void*. */
void xemu_metal_imgui_init(void *mtl_device);
void xemu_metal_imgui_shutdown(void);
void xemu_metal_imgui_new_frame(void);
void xemu_metal_imgui_render_draw_data(void *imgui_draw_data);
void xemu_metal_imgui_recreate_font_texture(void);

/* Returns the id<MTLDevice> (as void*) in use by the presenter, or NULL. */
void *xemu_metal_present_device(void);

// The framebuffer MTLTexture (as void*) sampled during the current UI frame.
// Owned by the Metal render loop (ui/xemu.c); valid while the framebuffer
// surface is held between nv2a_get_framebuffer_mtl_texture() and its release.
// Mirrors the static g_tex/g_flip_req used by the OpenGL presentation path.
#if defined(CONFIG_VULKAN)
extern void *g_metal_framebuffer_texture;
#endif

#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
#include <cstdint>
#include <vector>

/* Encode an offscreen copy of the emulator framebuffer (an id<MTLTexture>
 * passed as void*, as returned by nv2a_get_framebuffer_mtl_texture()) into
 * tightly packed RGBA8 pixels, mirroring the aspect-correction and flip
 * semantics of the GL screenshot path. Returns false if capture is
 * unavailable (e.g. the screen is blanked). The caller must hold a +1
 * reference on the texture for the duration of this call. */
bool xemu_metal_capture_framebuffer_rgba(void *mtl_texture, bool flip,
                                         std::vector<uint8_t> &rgba,
                                         int *out_width, int *out_height);
#endif

#endif /* __APPLE__ */

#endif /* XEMU_METAL_PRESENT_H */

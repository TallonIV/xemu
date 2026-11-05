/*
 * xemu User Interface
 *
 * Copyright (C) 2020-2022 Matt Borgerson
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <cstdint>
#include <fpng.h>
#include <vector>

#include "xemu-snapshots.h"
#include "xui/gl-helpers.hh"
#if defined(__APPLE__) && defined(CONFIG_VULKAN)
#include "xui/metal-present.h"
#endif

static GLuint display_tex = 0;
static bool display_flip = false;
#if defined(__APPLE__) && defined(CONFIG_VULKAN)
static void *display_mtl_texture = nullptr;
static bool display_mtl_flip = false;
#endif

void xemu_snapshots_set_framebuffer_texture(GLuint tex, bool flip)
{
    display_tex = tex;
    display_flip = flip;
}

#if defined(__APPLE__) && defined(CONFIG_VULKAN)
void xemu_snapshots_set_framebuffer_mtl_texture(void *mtl_texture, bool flip)
{
    display_mtl_texture = mtl_texture;
    display_mtl_flip = flip;
}
#endif

bool xemu_snapshots_load_png_to_texture(GLuint tex, void *buf, size_t size)
{
    std::vector<uint8_t> pixels;
    unsigned int width, height, channels;
    if (fpng::fpng_decode_memory(buf, size, pixels, width, height, channels,
                                 3) != fpng::FPNG_DECODE_SUCCESS) {
        return false;
    }

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex);

    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);

    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, width, height, 0, GL_RGB,
                 GL_UNSIGNED_BYTE, pixels.data());

    return true;
}

void *xemu_snapshots_create_framebuffer_thumbnail_png(size_t *size)
{
#if defined(__APPLE__) && defined(CONFIG_VULKAN)
    // Metal path: the Vulkan renderer exports its framebuffer as an MTLTexture
    // and does not populate a GL texture on Apple. Capture the current
    // framebuffer into RGBA and encode a thumbnail directly. Runs on the same
    // CAMetalQueue as the presenter; Metal is thread-safe for command-buffer
    // submission. If the presenter is inactive or the framebuffer is unset,
    // fall through to the GL check below (which correctly bails when there's
    // nothing to render).
    if (display_mtl_texture != nullptr &&
        xemu_metal_present_is_active()) {
        std::vector<uint8_t> rgba;
        int w = 0, h = 0;
        if (xemu_metal_capture_framebuffer_rgba(
                display_mtl_texture, display_mtl_flip, rgba, &w, &h,
                2 * XEMU_SNAPSHOT_THUMBNAIL_WIDTH,
                2 * XEMU_SNAPSHOT_THUMBNAIL_HEIGHT)) {
            std::vector<uint8_t> png;
            if (fpng::fpng_encode_image_to_memory(rgba.data(), w, h, 4, png)) {
                void *buf = g_malloc(png.size());
                memcpy(buf, png.data(), png.size());
                *size = png.size();
                return buf;
            }
        }
        return NULL;
    }
#endif

    /*
     * Avoids crashing if a snapshot is made on a thread with no GL context
     * Normally, this is not an issue, but it is better to fail safe than assert
     * here.
     * FIXME: Allow for dispatching a thumbnail request to the UI thread to
     * remove this altogether.
     */
    if (!SDL_GL_GetCurrentContext() || display_tex == 0) {
        return NULL;
    }

    std::vector<uint8_t> png;
    if (!RenderFramebufferToPng(display_tex, display_flip, png,
                                2 * XEMU_SNAPSHOT_THUMBNAIL_WIDTH,
                                2 * XEMU_SNAPSHOT_THUMBNAIL_HEIGHT)) {
        return NULL;
    }

    void *buf = g_malloc(png.size());
    memcpy(buf, png.data(), png.size());
    *size = png.size();
    return buf;
}

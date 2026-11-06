/*
 * Geforce NV2A PGRAPH Vulkan Renderer
 *
 * Copyright (c) 2024-2025 Matt Borgerson
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, see <http://www.gnu.org/licenses/>.
 */

#include "qemu/osdep.h"
#include "ui/xemu-settings.h"
#include "renderer.h"
#include "xemu-version.h"

#if defined(__APPLE__) && defined(VK_USE_PLATFORM_METAL_EXT)
#include <objc/runtime.h>
#include <dlfcn.h>
#endif

#define VkExtensionPropertiesArray GArray
#define StringArray GArray

static bool enable_validation = false;

static char const *const validation_layers[] = {
    "VK_LAYER_KHRONOS_validation",
};

static char const *const required_device_extensions[] = {
#ifdef WIN32
    VK_KHR_EXTERNAL_MEMORY_WIN32_EXTENSION_NAME,
    VK_KHR_EXTERNAL_SEMAPHORE_WIN32_EXTENSION_NAME,
#elif defined(__APPLE__) && defined(VK_USE_PLATFORM_METAL_EXT)
    /* On Apple Silicon the framebuffer is handed to the Metal compositor by
     * exporting the display image memory as an MTLTexture via
     * VK_EXT_external_memory_metal. Requiring it here makes driver support an
     * explicit gate: if the ICD does not expose it, Vulkan renderer
     * initialization fails cleanly and the user remains on OpenGL. Note that
     * KosmicKrisp advertises VK_EXT_external_memory_metal but NOT
     * VK_EXT_metal_objects, so we deliberately depend on the former. */
    VK_EXT_EXTERNAL_MEMORY_METAL_EXTENSION_NAME,
#else
    VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
    VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
#endif
};

static VKAPI_ATTR VkBool32 VKAPI_CALL debugCallback(
    VkDebugUtilsMessageSeverityFlagBitsEXT messageSeverity,
    VkDebugUtilsMessageTypeFlagsEXT messageType,
    const VkDebugUtilsMessengerCallbackDataEXT *pCallbackData, void *pUserData)
{
    fprintf(stderr, "[vk] %s\n", pCallbackData->pMessage);

    if ((messageType & VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT) &&
        (messageSeverity & (VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                            VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT))) {
        assert(!g_config.display.vulkan.assert_on_validation_msg);
    }
    return VK_FALSE;
}

static bool check_validation_layer_support(void)
{
    uint32_t num_available_layers;
    vkEnumerateInstanceLayerProperties(&num_available_layers, NULL);

    g_autofree VkLayerProperties *available_layers =
        g_malloc_n(num_available_layers, sizeof(VkLayerProperties));
    vkEnumerateInstanceLayerProperties(&num_available_layers, available_layers);

    for (int i = 0; i < ARRAY_SIZE(validation_layers); i++) {
        bool found = false;
        for (int j = 0; j < num_available_layers; j++) {
            if (!strcmp(validation_layers[i], available_layers[j].layerName)) {
                found = true;
                break;
            }
        }
        if (!found) {
            fprintf(stderr, "desired validation layer not found: %s\n",
                    validation_layers[i]);
            return false;
        }
    }

    return true;
}

static VkExtensionPropertiesArray *
get_available_instance_extensions(PGRAPHState *pg)
{
    uint32_t num_extensions = 0;

    VK_CHECK(
        vkEnumerateInstanceExtensionProperties(NULL, &num_extensions, NULL));

    VkExtensionPropertiesArray *extensions = g_array_sized_new(
        FALSE, FALSE, sizeof(VkExtensionProperties), num_extensions);

    g_array_set_size(extensions, num_extensions);
    VK_CHECK(vkEnumerateInstanceExtensionProperties(
        NULL, &num_extensions, (VkExtensionProperties *)extensions->data));

    return extensions;
}

static bool
is_extension_available(VkExtensionPropertiesArray *available_extensions,
                       const char *extension_name)
{
    for (int i = 0; i < available_extensions->len; i++) {
        VkExtensionProperties *e =
            &g_array_index(available_extensions, VkExtensionProperties, i);
        if (!strcmp(e->extensionName, extension_name)) {
            return true;
        }
    }

    return false;
}

static bool
add_extension_if_available(VkExtensionPropertiesArray *available_extensions,
                           StringArray *enabled_extension_names,
                           const char *desired_extension_name)
{
    if (is_extension_available(available_extensions, desired_extension_name)) {
        g_array_append_val(enabled_extension_names, desired_extension_name);
        return true;
    }

    fprintf(stderr, "Warning: extension not available: %s\n",
            desired_extension_name);
    return false;
}

static void
add_optional_instance_extension_names(PGRAPHState *pg,
                                      VkExtensionPropertiesArray *available_extensions,
                                      StringArray *enabled_extension_names)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    r->debug_utils_extension_enabled =
        g_config.display.vulkan.validation_layers &&
        add_extension_if_available(available_extensions, enabled_extension_names,
                                   VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
}

#if defined(VK_API_VERSION_1_4)
#define MAX_VK_API_VERSION VK_API_VERSION_1_4
#elif defined(VK_API_VERSION_1_3)
#define MAX_VK_API_VERSION VK_API_VERSION_1_3
#else
#define MAX_VK_API_VERSION VK_API_VERSION_1_2
#endif

static bool create_instance(PGRAPHState *pg, Error **errp)
{
    PGRAPHVkState *r = pg->vk_renderer_state;
    VkResult result;

#if defined(__APPLE__) && defined(VK_USE_PLATFORM_METAL_EXT)
    /* Locate and load the Vulkan loader explicitly. A Finder/launchd-launched
     * .app receives no DYLD_* search paths and the loader is intentionally not
     * bundled, so volkInitialize()'s default bare-soname dlopen cannot find a
     * Homebrew/MoltenVK/system-installed loader. Probe the common install
     * locations (honoring an optional VULKAN_LIBRARY hint), resolve
     * vkGetInstanceProcAddr, and hand it to volk. */
    static const char *const loader_candidates[] = {
        "libvulkan.1.dylib", /* bundled, or reachable via an embedded rpath */
        "/opt/homebrew/lib/libvulkan.1.dylib",
        "/usr/local/lib/libvulkan.1.dylib",
        "/opt/homebrew/opt/vulkan-loader/lib/libvulkan.1.dylib",
        "/usr/local/opt/vulkan-loader/lib/libvulkan.1.dylib",
        "libMoltenVK.dylib",
    };

    const char *override_path = getenv("VULKAN_LIBRARY");
    void *lib = NULL;
    if (override_path && *override_path) {
        lib = dlopen(override_path, RTLD_NOW | RTLD_LOCAL);
    }
    for (size_t i = 0; !lib && i < ARRAY_SIZE(loader_candidates); i++) {
        lib = dlopen(loader_candidates[i], RTLD_NOW | RTLD_LOCAL);
    }
    if (!lib) {
        error_setg(errp, "Failed to locate the Vulkan loader; install a Vulkan "
                         "loader/MoltenVK or set VULKAN_LIBRARY");
        return false;
    }

    PFN_vkGetInstanceProcAddr get_proc_addr =
        (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    if (!get_proc_addr) {
        error_setg(errp, "vkGetInstanceProcAddr not found in Vulkan loader");
        dlclose(lib);
        return false;
    }

    /* volkInitializeCustom returns void (it cannot fail once given a valid
     * vkGetInstanceProcAddr); remember the handle to dlclose() on finalize. */
    r->vulkan_library_handle = lib;
    volkInitializeCustom(get_proc_addr);
#else
    result = volkInitialize();
    if (result != VK_SUCCESS) {
        error_setg(errp, "volkInitialize failed");
        return false;
    }
#endif

    uint32_t instance_version = VK_API_VERSION_1_0;
    if (vkEnumerateInstanceVersion) {
        vkEnumerateInstanceVersion(&instance_version);
        instance_version = MIN(instance_version, MAX_VK_API_VERSION);
    }
    if (instance_version < VK_API_VERSION_1_1) {
        error_setg(errp, "Vulkan 1.1 or higher is required");
        return false;
    }
    r->vk_api_version = instance_version;

    VkApplicationInfo app_info = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "xemu",
        .applicationVersion = VK_MAKE_VERSION(
            xemu_version_major, xemu_version_minor, xemu_version_patch),
        .pEngineName = "No Engine",
        .engineVersion = VK_MAKE_VERSION(1, 0, 0),
        .apiVersion = r->vk_api_version,
    };

    g_autoptr(VkExtensionPropertiesArray) available_extensions =
        get_available_instance_extensions(pg);

    g_autoptr(StringArray) enabled_extension_names =
        g_array_new(FALSE, FALSE, sizeof(char *));

    add_optional_instance_extension_names(pg, available_extensions,
                                          enabled_extension_names);

    if (enabled_extension_names->len > 0) {
        fprintf(stderr, "Enabled instance extensions:\n");
        for (int i = 0; i < enabled_extension_names->len; i++) {
            fprintf(stderr, "- %s\n",
                    g_array_index(enabled_extension_names, char *, i));
        }
    }

    VkInstanceCreateInfo create_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledExtensionCount = enabled_extension_names->len,
        .ppEnabledExtensionNames =
            &g_array_index(enabled_extension_names, const char *, 0),
    };

    enable_validation = g_config.display.vulkan.validation_layers;

    VkValidationFeatureEnableEXT enables[] = {
        VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT,
        // VK_VALIDATION_FEATURE_ENABLE_BEST_PRACTICES_EXT,
    };

    VkValidationFeaturesEXT validationFeatures = {
        .sType = VK_STRUCTURE_TYPE_VALIDATION_FEATURES_EXT,
        .enabledValidationFeatureCount = ARRAY_SIZE(enables),
        .pEnabledValidationFeatures = enables,
    };

    if (enable_validation) {
        if (check_validation_layer_support()) {
            fprintf(stderr, "Warning: Validation layers enabled. Expect "
                            "performance impact.\n");
            create_info.enabledLayerCount = ARRAY_SIZE(validation_layers);
            create_info.ppEnabledLayerNames = validation_layers;
            create_info.pNext = &validationFeatures;
        } else {
            fprintf(stderr, "Warning: validation layers not available\n");
            enable_validation = false;
        }
    }

    result = vkCreateInstance(&create_info, NULL, &r->instance);
    if (result != VK_SUCCESS) {
        error_setg(errp, "Failed to create instance (%d)", result);
        return false;
    }

    volkLoadInstance(r->instance);

    if (r->debug_utils_extension_enabled) {
        VkDebugUtilsMessengerCreateInfoEXT messenger_info = {
            .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                               VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                               VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                           VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                           VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = debugCallback,
        };
        VK_CHECK(vkCreateDebugUtilsMessengerEXT(r->instance, &messenger_info,
                                                NULL, &r->debug_messenger));
    }

    return true;
}

static bool is_queue_family_indicies_complete(QueueFamilyIndices indices)
{
    return indices.queue_family >= 0;
}

QueueFamilyIndices pgraph_vk_find_queue_families(VkPhysicalDevice device)
{
    QueueFamilyIndices indices = {
        .queue_family = -1,
    };

    uint32_t num_queue_families = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(device, &num_queue_families, NULL);

    g_autofree VkQueueFamilyProperties *queue_families =
        g_malloc_n(num_queue_families, sizeof(VkQueueFamilyProperties));
    vkGetPhysicalDeviceQueueFamilyProperties(device, &num_queue_families,
                                             queue_families);

    for (int i = 0; i < num_queue_families; i++) {
        VkQueueFamilyProperties queueFamily = queue_families[i];
        // FIXME: Support independent graphics, compute queues
        int required_flags = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
        if ((queueFamily.queueFlags & required_flags) == required_flags) {
            indices.queue_family = i;
        }
        if (is_queue_family_indicies_complete(indices)) {
            break;
        }
    }

    return indices;
}

static VkExtensionPropertiesArray *
get_available_device_extensions(VkPhysicalDevice device)
{
    uint32_t num_extensions = 0;

    VK_CHECK(vkEnumerateDeviceExtensionProperties(device, NULL, &num_extensions,
                                                  NULL));

    VkExtensionPropertiesArray *extensions = g_array_sized_new(
        FALSE, FALSE, sizeof(VkExtensionProperties), num_extensions);

    g_array_set_size(extensions, num_extensions);
    VK_CHECK(vkEnumerateDeviceExtensionProperties(
        device, NULL, &num_extensions,
        (VkExtensionProperties *)extensions->data));

    return extensions;
}

static StringArray *get_required_device_extension_names(void)
{
    StringArray *extensions =
        g_array_sized_new(FALSE, FALSE, sizeof(char *),
                          ARRAY_SIZE(required_device_extensions));

    g_array_append_vals(extensions, required_device_extensions,
                        ARRAY_SIZE(required_device_extensions));

    return extensions;
}

static void add_optional_device_extension_names(
    PGRAPHState *pg, VkExtensionPropertiesArray *available_extensions,
    StringArray *enabled_extension_names)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    r->custom_border_color_extension_enabled =
        add_extension_if_available(available_extensions, enabled_extension_names,
                                   VK_EXT_CUSTOM_BORDER_COLOR_EXTENSION_NAME);

    r->memory_budget_extension_enabled = add_extension_if_available(
        available_extensions, enabled_extension_names,
        VK_EXT_MEMORY_BUDGET_EXTENSION_NAME);
}

static bool check_device_support_required_extensions(VkPhysicalDevice device)
{
    g_autoptr(VkExtensionPropertiesArray) available_extensions =
        get_available_device_extensions(device);

    for (int i = 0; i < ARRAY_SIZE(required_device_extensions); i++) {
        if (!is_extension_available(available_extensions,
                                    required_device_extensions[i])) {
            fprintf(stderr, "required device extension not found: %s\n",
                    required_device_extensions[i]);
            return false;
        }
    }

    return true;
}

#if defined(__APPLE__) && defined(VK_USE_PLATFORM_METAL_EXT)
/* Verify the physical device can export the offscreen framebuffer as an
 * MTLTexture via VK_EXT_external_memory_metal. This is the mechanism the Metal
 * presenter uses to sample the Vulkan-rendered image, so a device that
 * advertises the extension but not the MTLTEXTURE export handle type must be
 * rejected here rather than failing later at display image creation. The
 * dedicated vkGetPhysicalDeviceExternalImageFormatProperties() entry point is
 * not exported by all volk builds, so we query the same information through
 * vkGetPhysicalDeviceImageFormatProperties2() by chaining a
 * VkPhysicalDeviceExternalImageFormatInfo (input) to a
 * VkExternalImageFormatProperties (output). */
static bool check_device_supports_metal_texture_export(VkPhysicalDevice device)
{
    VkExternalImageFormatProperties external_properties = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
        .pNext = NULL,
    };
    VkPhysicalDeviceExternalImageFormatInfo external_image_info = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
        .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLTEXTURE_BIT_EXT,
        .pNext = &external_properties,
    };
    VkImageFormatProperties2 format_properties = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
        .pNext = &external_image_info,
    };
    VkPhysicalDeviceImageFormatInfo2 image_format_info = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .type = VK_IMAGE_TYPE_2D,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .flags = 0,
    };

    VkResult result = vkGetPhysicalDeviceImageFormatProperties2(
        device, &image_format_info, &format_properties);

    const VkExternalMemoryProperties *ext_mem =
        &external_properties.externalMemoryProperties;
    if (result != VK_SUCCESS ||
        !(ext_mem->compatibleHandleTypes &
          VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLTEXTURE_BIT_EXT) ||
        !(ext_mem->externalMemoryFeatures &
          VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT)) {
        fprintf(stderr,
                "device does not support VK_EXT_external_memory_metal "
                "MTLTEXTURE export for the framebuffer\n");
        return false;
    }

    return true;
}
#endif

static bool check_device_support_required_formats(VkPhysicalDevice device)
{
    const VkFormatFeatureFlags required_features =
        VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
    bool all_supported = true;

    for (int i = 0; i < ARRAY_SIZE(kelvin_color_format_vk_map); i++) {
        VkFormat format = kelvin_color_format_vk_map[i].vk_format;
        if (format == VK_FORMAT_UNDEFINED) {
            continue;
        }
        VkFormatProperties props;
        vkGetPhysicalDeviceFormatProperties(device, format, &props);
        if ((props.optimalTilingFeatures & required_features) !=
            required_features) {
            fprintf(stderr,
                    "required texture format not supported: 0x%02x "
                    "(VkFormat %d)\n",
                    i, format);
            all_supported = false;
        }
    }

    for (int i = 0; i < ARRAY_SIZE(kelvin_surface_color_format_vk_map); i++) {
        const SurfaceFormatInfo *f = &kelvin_surface_color_format_vk_map[i];
        if (f->host_bytes_per_pixel &&
            !pgraph_vk_is_image_format_supported(device, f->vk_format,
                                                 f->usage)) {
            fprintf(stderr,
                    "required surface format not supported: 0x%02x "
                    "(VkFormat %d)\n",
                    i, f->vk_format);
            all_supported = false;
        }
    }

    if (!pgraph_vk_is_image_format_supported(device, zeta_d16.vk_format,
                                             zeta_d16.usage)) {
        fprintf(stderr, "required depth format not supported: VkFormat %d\n",
                zeta_d16.vk_format);
        all_supported = false;
    }

    // Either depth-stencil format is acceptable; surface init picks one.
    if (!pgraph_vk_is_image_format_supported(device,
                                             zeta_d24_unorm_s8_uint.vk_format,
                                             zeta_d24_unorm_s8_uint.usage) &&
        !pgraph_vk_is_image_format_supported(
            device, zeta_d32_sfloat_s8_uint.vk_format,
            zeta_d32_sfloat_s8_uint.usage)) {
        fprintf(stderr,
                "no supported depth-stencil format (VkFormat %d or %d)\n",
                zeta_d24_unorm_s8_uint.vk_format,
                zeta_d32_sfloat_s8_uint.vk_format);
        all_supported = false;
    }

    return all_supported;
}

static bool is_device_compatible(VkPhysicalDevice device)
{
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(device, &props);
    if (props.apiVersion < VK_API_VERSION_1_1) {
        return false;
    }

    QueueFamilyIndices indices = pgraph_vk_find_queue_families(device);

    return is_queue_family_indicies_complete(indices) &&
           check_device_support_required_extensions(device) &&
#if defined(__APPLE__) && defined(VK_USE_PLATFORM_METAL_EXT)
           check_device_supports_metal_texture_export(device) &&
#endif
           check_device_support_required_formats(device);
    // FIXME: Check vram
}

static bool select_physical_device(PGRAPHState *pg, Error **errp)
{
    PGRAPHVkState *r = pg->vk_renderer_state;
    VkResult result;

    uint32_t num_physical_devices = 0;

    result =
        vkEnumeratePhysicalDevices(r->instance, &num_physical_devices, NULL);
    if (result != VK_SUCCESS || num_physical_devices == 0) {
        error_setg(errp, "Failed to find GPUs with Vulkan support");
        return false;
    }

    g_autofree VkPhysicalDevice *devices =
        g_malloc_n(num_physical_devices, sizeof(VkPhysicalDevice));
    vkEnumeratePhysicalDevices(r->instance, &num_physical_devices, devices);

    const char *preferred_device = g_config.display.vulkan.preferred_physical_device;
    int preferred_device_index = -1;

    fprintf(stderr, "Available physical devices:\n");
    for (int i = 0; i < num_physical_devices; i++) {
        vkGetPhysicalDeviceProperties(devices[i], &r->device_props);
        bool is_preferred =
            preferred_device &&
            !strcmp(r->device_props.deviceName, preferred_device);
        if (is_preferred) {
            preferred_device_index = i;
        }
        fprintf(stderr, "- %s%s\n", r->device_props.deviceName,
                is_preferred ? " *" : "");
    }

    r->physical_device = VK_NULL_HANDLE;

    if (preferred_device_index >= 0 &&
        is_device_compatible(devices[preferred_device_index])) {
        r->physical_device = devices[preferred_device_index];
    } else {
        for (int i = 0; i < num_physical_devices; i++) {
            if (is_device_compatible(devices[i])) {
                r->physical_device = devices[i];
                break;
            }
        }
    }
    if (r->physical_device == VK_NULL_HANDLE) {
        error_setg(errp, "Failed to find a suitable GPU");
        return false;
    }

    vkGetPhysicalDeviceProperties(r->physical_device, &r->device_props);
    xemu_settings_set_string(&g_config.display.vulkan.preferred_physical_device,
                             r->device_props.deviceName);
    r->vk_api_version = MIN(r->vk_api_version, r->device_props.apiVersion);

    fprintf(stderr,
            "Selected physical device: %s\n"
            "- Vendor: %x, Device: %x\n"
            "- Driver Version: %d.%d.%d\n",
            r->device_props.deviceName,
            r->device_props.vendorID,
            r->device_props.deviceID,
            VK_VERSION_MAJOR(r->device_props.driverVersion),
            VK_VERSION_MINOR(r->device_props.driverVersion),
            VK_VERSION_PATCH(r->device_props.driverVersion));

    return true;
}

static bool create_logical_device(PGRAPHState *pg, Error **errp)
{
    PGRAPHVkState *r = pg->vk_renderer_state;
    VkResult result;

    QueueFamilyIndices indices =
        pgraph_vk_find_queue_families(r->physical_device);

    g_autoptr(VkExtensionPropertiesArray) available_extensions =
        get_available_device_extensions(r->physical_device);

    g_autoptr(StringArray) enabled_extension_names =
        get_required_device_extension_names();

    add_optional_device_extension_names(pg, available_extensions,
                                        enabled_extension_names);

    fprintf(stderr, "Enabled device extensions:\n");
    for (int i = 0; i < enabled_extension_names->len; i++) {
        fprintf(stderr, "- %s\n",
                g_array_index(enabled_extension_names, char *, i));
    }

    float queuePriority = 1.0f;

    VkDeviceQueueCreateInfo queue_create_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = indices.queue_family,
        .queueCount = 1,
        .pQueuePriorities = &queuePriority,
    };

    // Check device features
    VkPhysicalDeviceFeatures physical_device_features;
    vkGetPhysicalDeviceFeatures(r->physical_device, &physical_device_features);
    memset(&r->enabled_physical_device_features, 0,
           sizeof(r->enabled_physical_device_features));

    struct {
        const char *name;
        VkBool32 available, *enabled;
        bool required;
    } desired_features[] = {
        // clang-format off
        #define F(n, req) { \
            .name = #n, \
            .available = physical_device_features.n, \
            .enabled = &r->enabled_physical_device_features.n, \
            .required = req, \
        }
        F(depthClamp, true),
        F(fillModeNonSolid, true),
        F(geometryShader, true),
        F(occlusionQueryPrecise, true),
        F(samplerAnisotropy, false),
        F(shaderClipDistance, true),
        F(shaderTessellationAndGeometryPointSize, true),
        F(wideLines, false),
        #undef F
        // clang-format on
    };

    bool all_required_features_available = true;
    for (int i = 0; i < ARRAY_SIZE(desired_features); i++) {
        if (desired_features[i].required &&
            desired_features[i].available != VK_TRUE) {
            fprintf(stderr,
                    "Error: Device does not support required feature %s\n",
                    desired_features[i].name);
            all_required_features_available = false;
        }
        *desired_features[i].enabled = desired_features[i].available;
    }

    if (!all_required_features_available) {
        error_setg(errp, "Device does not support required features");
        return false;
    }

    void *next_struct = NULL;

    VkPhysicalDeviceCustomBorderColorFeaturesEXT custom_border_features;
    if (r->custom_border_color_extension_enabled) {
        custom_border_features = (VkPhysicalDeviceCustomBorderColorFeaturesEXT){
            .sType =
                VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CUSTOM_BORDER_COLOR_FEATURES_EXT,
            .customBorderColors = VK_TRUE,
            .pNext = next_struct,
        };
        next_struct = &custom_border_features;
    }

    VkDeviceCreateInfo device_create_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_create_info,
        .pEnabledFeatures = &r->enabled_physical_device_features,
        .enabledExtensionCount = enabled_extension_names->len,
        .ppEnabledExtensionNames =
            &g_array_index(enabled_extension_names, const char *, 0),
        .pNext = next_struct,
    };

    if (enable_validation) {
        device_create_info.enabledLayerCount = ARRAY_SIZE(validation_layers);
        device_create_info.ppEnabledLayerNames = validation_layers;
    }

    result = vkCreateDevice(r->physical_device, &device_create_info, NULL,
                            &r->device);
    if (result != VK_SUCCESS) {
        error_setg(errp, "Failed to create logical device (%d)", result);
        return false;
    }

    vkGetDeviceQueue(r->device, indices.queue_family, 0, &r->queue);

    /* NOTE: The Metal presenter owns its own MTLDevice via
     * MTLCreateSystemDefaultDevice(), and the framebuffer reaches it as an
     * exported MTLTexture handle (VK_EXT_external_memory_metal, see
     * display.c). The renderer therefore no longer exports an MTLDevice here
     * (that used to depend on VK_EXT_metal_objects, which KosmicKrisp lacks). */

    return true;
}

uint32_t pgraph_vk_get_memory_type(PGRAPHState *pg, uint32_t type_bits,
                                   VkMemoryPropertyFlags properties)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    VkPhysicalDeviceMemoryProperties prop;
    vkGetPhysicalDeviceMemoryProperties(r->physical_device, &prop);
    for (uint32_t i = 0; i < prop.memoryTypeCount; i++) {
        if ((prop.memoryTypes[i].propertyFlags & properties) == properties &&
            type_bits & (1 << i)) {
            return i;
        }
    }
    return 0xFFFFFFFF; // Unable to find memoryType
}

static bool init_allocator(PGRAPHState *pg, Error **errp)
{
    PGRAPHVkState *r = pg->vk_renderer_state;
    VkResult result;

    VmaAllocatorCreateInfo create_info = {
        .flags = (r->memory_budget_extension_enabled ?
                      VMA_ALLOCATOR_CREATE_EXT_MEMORY_BUDGET_BIT :
                      0),
        .vulkanApiVersion = r->vk_api_version,
        .instance = r->instance,
        .physicalDevice = r->physical_device,
        .device = r->device,
    };

    VmaVulkanFunctions vulkan_functions;
    VkResult res = vmaImportVulkanFunctionsFromVolk(&create_info, &vulkan_functions);
    if (res != VK_SUCCESS) {
        error_setg(errp, "vmaImportVulkanFunctionsFromVolk failed");
        return false;
    }
    create_info.pVulkanFunctions = &vulkan_functions;

    result = vmaCreateAllocator(&create_info, &r->allocator);
    if (result != VK_SUCCESS) {
        error_setg(errp, "vmaCreateAllocator failed");
        return false;
    }

    return true;
}

void pgraph_vk_init_instance(PGRAPHState *pg, Error **errp)
{
    if (create_instance(pg, errp) &&
        select_physical_device(pg, errp) &&
        create_logical_device(pg, errp) &&
        init_allocator(pg, errp)) {
        return;
    }

    pgraph_vk_finalize_instance(pg);

    const char *msg = "Failed to initialize Vulkan renderer";
    if (*errp) {
        error_prepend(errp, "%s: ", msg);
    } else {
        error_setg(errp, "%s", msg);
    }
}

void pgraph_vk_finalize_instance(PGRAPHState *pg)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    if (r->allocator != VK_NULL_HANDLE) {
        vmaDestroyAllocator(r->allocator);
        r->allocator = VK_NULL_HANDLE;
    }

    if (r->device != VK_NULL_HANDLE) {
        vkDestroyDevice(r->device, NULL);
        r->device = VK_NULL_HANDLE;
    }

    if (r->debug_messenger != VK_NULL_HANDLE) {
        vkDestroyDebugUtilsMessengerEXT(r->instance, r->debug_messenger, NULL);
        r->debug_messenger = VK_NULL_HANDLE;
    }

    if (r->instance != VK_NULL_HANDLE) {
        vkDestroyInstance(r->instance, NULL);
        r->instance = VK_NULL_HANDLE;
    }

    volkFinalize();

#if defined(__APPLE__) && defined(VK_USE_PLATFORM_METAL_EXT)
    /* Release the dlopen()'ed Vulkan loader acquired in create_instance(). */
    if (r->vulkan_library_handle) {
        dlclose(r->vulkan_library_handle);
        r->vulkan_library_handle = NULL;
    }
#endif
}

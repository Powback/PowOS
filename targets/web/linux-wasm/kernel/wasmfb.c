// SPDX-License-Identifier: GPL-2.0-only
/*
 * PowOS: a framebuffer shown by the Wasm host (/dev/fb0 -> a canvas in the page).
 *
 * The kernel's memory is the page's shared WebAssembly.Memory, so the page reads the pixels straight out of it every
 * animation frame (runtime/index.html); the only host call tells it where they are:
 *
 *   wasm_driver_fb_init(base, width, height, stride)    32-bit XRGB, little-endian (B, G, R, X in memory)
 *
 * NOMMU: user mmap of /dev/fb0 maps the buffer itself (FB_PROVIDE_GET_FB_UNMAPPED_AREA), so it must be one contiguous
 * allocation.
 */
#include <linux/module.h>
#include <linux/fb.h>
#include <linux/mm.h>
#include <linux/gfp.h>

extern void wasm_driver_fb_init(void *base, u32 width, u32 height, u32 stride);

#define WASMFB_WIDTH	1280
#define WASMFB_HEIGHT	800

static u32 wasmfb_pseudo_palette[16];

static int wasmfb_setcolreg(unsigned int regno, unsigned int red, unsigned int green, unsigned int blue,
			    unsigned int transp, struct fb_info *info)
{
	if (regno >= 16)
		return 1;
	wasmfb_pseudo_palette[regno] = ((red >> 8) << 16) | ((green >> 8) << 8) | (blue >> 8);
	return 0;
}

static const struct fb_ops wasmfb_ops = {
	.owner		= THIS_MODULE,
	__FB_DEFAULT_SYSMEM_OPS_RDWR,
	.fb_setcolreg	= wasmfb_setcolreg,
	__FB_DEFAULT_SYSMEM_OPS_DRAW,
};

static int __init wasmfb_init(void)
{
	u32 stride = WASMFB_WIDTH * 4;
	size_t size = PAGE_ALIGN(stride * WASMFB_HEIGHT);
	struct fb_info *info;
	void *buf;
	int err;

	buf = alloc_pages_exact(size, GFP_KERNEL | __GFP_ZERO);
	if (!buf)
		return -ENOMEM;
	info = framebuffer_alloc(0, NULL);
	if (!info) {
		free_pages_exact(buf, size);
		return -ENOMEM;
	}
	strscpy(info->fix.id, "wasmfb", sizeof(info->fix.id));
	info->fix.type = FB_TYPE_PACKED_PIXELS;
	info->fix.visual = FB_VISUAL_TRUECOLOR;
	info->fix.line_length = stride;
	info->fix.smem_start = (unsigned long)buf;
	info->fix.smem_len = size;
	info->fix.accel = FB_ACCEL_NONE;

	info->var.xres = info->var.xres_virtual = WASMFB_WIDTH;
	info->var.yres = info->var.yres_virtual = WASMFB_HEIGHT;
	info->var.bits_per_pixel = 32;
	info->var.red = (struct fb_bitfield){ 16, 8, 0 };
	info->var.green = (struct fb_bitfield){ 8, 8, 0 };
	info->var.blue = (struct fb_bitfield){ 0, 8, 0 };
	info->var.transp = (struct fb_bitfield){ 24, 0, 0 };
	info->var.activate = FB_ACTIVATE_NOW;
	info->var.height = info->var.width = -1;
	info->var.vmode = FB_VMODE_NONINTERLACED;

	info->screen_buffer = buf;
	info->screen_size = size;
	info->fbops = &wasmfb_ops;
	info->pseudo_palette = wasmfb_pseudo_palette;
	info->flags = FBINFO_VIRTFB;

	err = register_framebuffer(info);
	if (err) {
		framebuffer_release(info);
		free_pages_exact(buf, size);
		return err;
	}
	wasm_driver_fb_init(buf, WASMFB_WIDTH, WASMFB_HEIGHT, stride);
	fb_info(info, "%ux%u, shown by the host\n", WASMFB_WIDTH, WASMFB_HEIGHT);
	return 0;
}
device_initcall(wasmfb_init);

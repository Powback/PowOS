// PowOS on Linux/Wasm: the first graphical program - /dev/fb0 out, /dev/input/event0 in.
// Draws a gradient, a cursor that follows the pointer, and a block per key pressed (left to right). Ctrl-C to quit.
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

static uint32_t *fb;
static int W, H, stride;

static void rect(int x, int y, int w, int h, uint32_t c)
{
	for (int j = y < 0 ? 0 : y; j < y + h && j < H; j++)
		for (int i = x < 0 ? 0 : x; i < x + w && i < W; i++)
			fb[j * stride + i] = c;
}

static uint32_t bg(int x, int y)
{
	return (uint32_t)((40 + 60 * y / H) << 16 | (20 + 40 * x / W) << 8 | (90 + 120 * y / H));
}

static void unrect(int x, int y, int w, int h)
{
	for (int j = y < 0 ? 0 : y; j < y + h && j < H; j++)
		for (int i = x < 0 ? 0 : x; i < x + w && i < W; i++)
			fb[j * stride + i] = bg(i, j);
}

int main(int argc, char **argv)
{
	struct fb_var_screeninfo var;
	struct fb_fix_screeninfo fix;
	int fd = open("/dev/fb0", O_RDWR);
	if (fd < 0 || ioctl(fd, FBIOGET_VSCREENINFO, &var) || ioctl(fd, FBIOGET_FSCREENINFO, &fix)) {
		perror("fb0");
		return 1;
	}
	W = var.xres; H = var.yres; stride = fix.line_length / 4;
	fb = mmap(NULL, fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (fb == MAP_FAILED) {
		perror("mmap fb0");
		return 1;
	}
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++)
			fb[y * stride + x] = bg(x, y);
	rect(40, 40, 360, 8, 0xffd040);	/* a PowOS-ish bar */
	printf("fbdemo: %dx%d, move the pointer / type on the canvas\n", W, H);

	int in = open("/dev/input/event0", O_RDONLY | O_NONBLOCK);
	int cx = W / 2, cy = H / 2, keys = 0;
	struct input_event ev;
	for (;;) {
		int moved = 0, ox = cx, oy = cy;
		while (in >= 0 && read(in, &ev, sizeof(ev)) == sizeof(ev)) {
			if (ev.type == EV_ABS && ev.code == ABS_X) { cx = ev.value * W / 32768; moved = 1; }
			if (ev.type == EV_ABS && ev.code == ABS_Y) { cy = ev.value * H / 32768; moved = 1; }
			if (ev.type == EV_KEY && ev.value == 1 && ev.code < BTN_MISC) {
				rect(40 + (keys % 40) * 28, 80 + (keys / 40) * 28, 22, 22, 0x40c0ff + ev.code * 1999);
				keys++;
			}
			if (ev.type == EV_KEY && ev.code == BTN_LEFT && ev.value == 1)
				rect(cx - 6, cy - 6, 12, 12, 0xffffff);
		}
		if (moved) {
			unrect(ox - 4, oy - 4, 9, 9);
			rect(cx - 4, cy - 4, 9, 9, 0xff4060);
		}
		usleep(16000);
	}
}

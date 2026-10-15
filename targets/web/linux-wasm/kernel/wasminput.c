// SPDX-License-Identifier: GPL-2.0-only
/*
 * PowOS: keyboard and pointer from the Wasm host (the page's canvas) as a Linux input device (/dev/input/eventN).
 *
 * The kernel allocates an event ring in its memory - the page's shared WebAssembly.Memory - and tells the page where
 * it is; the page writes events into it with Atomics (runtime/index.html), and a delayed work item drains it here
 * every 10 ms. Same format as PowOS Web's QEMU display (targets/web/qemu/ui/web.c):
 *
 *   s32 head (page writes), s32 tail (kernel writes), then RING_SLOTS events of 4 s32: [type, a, b, 0]
 *   type 1 key (a = Linux keycode, b = down), 2 absolute pointer (a, b = x, y in 0..32767),
 *   3 button (a = 0 left / 1 middle / 2 right / 3 wheel up / 4 wheel down, b = down)
 *
 *   wasm_driver_input_init(ring, slots)
 */
#include <linux/module.h>
#include <linux/input.h>
#include <linux/workqueue.h>
#include <linux/slab.h>

extern void wasm_driver_input_init(void *ring, u32 slots);

#define RING_SLOTS	1024
#define EV_T_KEY	1
#define EV_T_ABS	2
#define EV_T_BTN	3

static s32 *ring;
static struct input_dev *wasminput_dev;
static struct delayed_work wasminput_work;

static const unsigned short wasminput_buttons[] = { BTN_LEFT, BTN_MIDDLE, BTN_RIGHT };

static void wasminput_drain(struct work_struct *work)
{
	s32 head = smp_load_acquire(&ring[0]);
	s32 tail = ring[1];
	bool any = false;

	while (tail != head) {
		s32 *ev = &ring[2 + (tail % RING_SLOTS) * 4];

		switch (ev[0]) {
		case EV_T_KEY:
			if (ev[1] > 0 && ev[1] < KEY_MAX)
				input_report_key(wasminput_dev, ev[1], ev[2]);
			break;
		case EV_T_ABS:
			input_report_abs(wasminput_dev, ABS_X, ev[1]);
			input_report_abs(wasminput_dev, ABS_Y, ev[2]);
			break;
		case EV_T_BTN:
			if (ev[1] >= 0 && ev[1] < ARRAY_SIZE(wasminput_buttons))
				input_report_key(wasminput_dev, wasminput_buttons[ev[1]], ev[2]);
			else if ((ev[1] == 3 || ev[1] == 4) && ev[2])
				input_report_rel(wasminput_dev, REL_WHEEL, ev[1] == 3 ? 1 : -1);
			break;
		}
		any = true;
		tail = (tail + 1) % (RING_SLOTS * 1024);
	}
	smp_store_release(&ring[1], tail);
	if (any)
		input_sync(wasminput_dev);
	schedule_delayed_work(&wasminput_work, msecs_to_jiffies(10));
}

static int __init wasminput_init(void)
{
	struct input_dev *dev;
	int k, err;

	ring = kzalloc((2 + RING_SLOTS * 4) * sizeof(s32), GFP_KERNEL);
	if (!ring)
		return -ENOMEM;
	dev = input_allocate_device();
	if (!dev) {
		kfree(ring);
		return -ENOMEM;
	}
	dev->name = "PowOS Web keyboard and pointer";
	dev->phys = "wasm/input0";
	dev->id.bustype = BUS_VIRTUAL;
	__set_bit(EV_KEY, dev->evbit);
	__set_bit(EV_ABS, dev->evbit);
	__set_bit(EV_REL, dev->evbit);
	for (k = KEY_ESC; k < KEY_MICMUTE; k++)
		__set_bit(k, dev->keybit);
	for (k = 0; k < ARRAY_SIZE(wasminput_buttons); k++)
		__set_bit(wasminput_buttons[k], dev->keybit);
	__set_bit(REL_WHEEL, dev->relbit);
	input_set_abs_params(dev, ABS_X, 0, 32767, 0, 0);
	input_set_abs_params(dev, ABS_Y, 0, 32767, 0, 0);
	err = input_register_device(dev);
	if (err) {
		input_free_device(dev);
		kfree(ring);
		return err;
	}
	wasminput_dev = dev;
	INIT_DELAYED_WORK(&wasminput_work, wasminput_drain);
	wasm_driver_input_init(ring, RING_SLOTS);
	schedule_delayed_work(&wasminput_work, msecs_to_jiffies(10));
	return 0;
}
device_initcall(wasminput_init);

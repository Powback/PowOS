// SPDX-License-Identifier: GPL-2.0-only
/*
 * PowOS: a read-only block device backed by the Wasm host - the page streams the disk on demand.
 *
 * Every kernel task runs in its own Web Worker (Linux/Wasm), so a read that blocks in the host blocks only the task
 * that issued it. The host side (runtime/linux-worker.js) fetches the requested range of the published disk image with
 * a synchronous HTTP Range request and keeps recently read blocks.
 *
 *   wasm_driver_blk_sectors()                 size of the disk in 512-byte sectors (0: no disk)
 *   wasm_driver_blk_read(sector, buf, len)    read len bytes (a multiple of 512) at sector into buf; returns len or < 0
 */
#include <linux/module.h>
#include <linux/blkdev.h>
#include <linux/bio.h>
#include <linux/highmem.h>

extern u32 wasm_driver_blk_sectors(void);
extern int wasm_driver_blk_read(u32 sector, void *buf, u32 len);

static struct gendisk *wasm_blk_disk;

static void wasm_blk_submit_bio(struct bio *bio)
{
	struct bio_vec bv;
	struct bvec_iter iter;
	sector_t sector = bio->bi_iter.bi_sector;

	if (bio_op(bio) == REQ_OP_FLUSH) {
		bio_endio(bio);
		return;
	}
	if (bio_op(bio) != REQ_OP_READ) {
		bio_io_error(bio);	/* read-only device */
		return;
	}
	bio_for_each_segment(bv, bio, iter) {
		void *kaddr = bvec_kmap_local(&bv);
		int n = wasm_driver_blk_read(sector, kaddr, bv.bv_len);

		kunmap_local(kaddr);
		if (n != bv.bv_len) {
			bio_io_error(bio);
			return;
		}
		sector += bv.bv_len >> SECTOR_SHIFT;
	}
	bio_endio(bio);
}

static const struct block_device_operations wasm_blk_fops = {
	.owner		= THIS_MODULE,
	.submit_bio	= wasm_blk_submit_bio,
};

static int __init wasm_blk_init(void)
{
	struct queue_limits lim = {
		.logical_block_size	= SECTOR_SIZE,
		.physical_block_size	= PAGE_SIZE,
		.features		= BLK_FEAT_SYNCHRONOUS,
	};
	u32 sectors = wasm_driver_blk_sectors();
	int major, err;

	if (!sectors)
		return 0;	/* the page published no disk */

	major = register_blkdev(0, "wasmblk");
	if (major < 0)
		return major;
	wasm_blk_disk = blk_alloc_disk(&lim, NUMA_NO_NODE);
	if (IS_ERR(wasm_blk_disk)) {
		unregister_blkdev(major, "wasmblk");
		return PTR_ERR(wasm_blk_disk);
	}
	wasm_blk_disk->major = major;
	wasm_blk_disk->first_minor = 0;
	wasm_blk_disk->minors = 1;
	wasm_blk_disk->fops = &wasm_blk_fops;
	strscpy(wasm_blk_disk->disk_name, "wasmblk0", DISK_NAME_LEN);
	set_capacity(wasm_blk_disk, sectors);
	set_disk_ro(wasm_blk_disk, true);
	err = add_disk(wasm_blk_disk);
	if (err) {
		put_disk(wasm_blk_disk);
		unregister_blkdev(major, "wasmblk");
		return err;
	}
	pr_info("wasmblk0: %u sectors (%u MiB), streamed by the host\n", sectors, sectors >> 11);
	return 0;
}
device_initcall(wasm_blk_init);

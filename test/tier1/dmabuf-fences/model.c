// SPDX-License-Identifier: GPL-2.0-only
/*
 * Userspace model of the kernel's dma_fence / dma_fence_array / dma_resv, to run the SHIPPED dma_buf_resv_fence (cut
 * out of targets/android/kernel/patches/000{4,5}-*.patch by ../test-kernel-dmabuf-fences.sh into resv_fence.inc)
 * against upstream's dma_fence_unwrap iterator and __dma_fence_unwrap_merge, copied verbatim below from the phone's
 * android13-5.15 tree (drivers/dma-buf/dma-fence-unwrap.c, dma-fence-array.c, include/linux/dma-fence-chain.h).
 *
 * What it measures: a game presenting N frames through Mesa's WSI = per frame one IMPORT_SYNC_FILE(WRITE) of that
 * frame's GPU fence (dma_buf_import_sync_file's write branch) and one EXPORT_SYNC_FILE(READ) (Xwayland's wait),
 * frames finishing in order. Then the buffer is freed (the game closing): the deepest nesting of fence releases that
 * puts - each level is one dma_fence_array_release frame on the kernel's 16 KB stack - and whether every fence was
 * freed. The model's release recursion is the kernel's.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t u64;
typedef int64_t ktime_t;
#define GFP_KERNEL 0
#define ENOMEM 12
#define ns_to_ktime(x) ((ktime_t)(x))
#define ktime_after(a, b) ((a) > (b))
static ktime_t ktime_get(void) { static ktime_t t; return ++t; }

struct dma_fence_ops { int kind; };
static const struct dma_fence_ops plain_ops = {0}, dma_fence_array_ops = {1}, dma_fence_chain_ops = {2};
struct dma_fence {
	int refcount;
	u64 context, seqno;
	bool signaled;
	ktime_t timestamp;
	const struct dma_fence_ops *ops;
};
struct dma_fence_array {
	struct dma_fence base;
	unsigned num_fences;
	struct dma_fence **fences;
};
struct dma_fence_chain { struct dma_fence base; struct dma_fence *fence; };  /* never built here */

static long live, depth, max_depth;
static u64 next_context = 100;
static u64 dma_fence_context_alloc(unsigned n) { u64 c = next_context; next_context += n; return c; }

static void *krealloc(void *p, size_t n, int gfp) { (void)gfp; return realloc(p, n); }
static void *kmalloc_array(size_t n, size_t s, int gfp) { (void)gfp; return malloc(n * s ? n * s : 1); }
static void *kmemdup(const void *p, size_t n, int gfp) { void *q = malloc(n ? n : 1); (void)gfp; if (q) memcpy(q, p, n); return q; }
static void kfree(const void *p) { free((void *)p); }

static struct dma_fence_array *to_dma_fence_array(struct dma_fence *f)
{
	return f && f->ops == &dma_fence_array_ops ? (struct dma_fence_array *)f : NULL;
}
static struct dma_fence_chain *to_dma_fence_chain(struct dma_fence *f)
{
	return f && f->ops == &dma_fence_chain_ops ? (struct dma_fence_chain *)f : NULL;
}
static struct dma_fence *dma_fence_get(struct dma_fence *f) { if (f) f->refcount++; return f; }
static void dma_fence_put(struct dma_fence *f)
{
	struct dma_fence_array *a;
	unsigned i;

	if (!f || --f->refcount)
		return;
	if (++depth > max_depth)  /* one more release frame on the stack */
		max_depth = depth;
	if ((a = to_dma_fence_array(f))) {  /* dma_fence_array_release */
		for (i = 0; i < a->num_fences; i++)
			dma_fence_put(a->fences[i]);
		kfree(a->fences);
	}
	free(f);
	live--;
	depth--;
}
static struct dma_fence *new_fence(u64 context, u64 seqno, bool signaled)
{
	struct dma_fence *f = calloc(1, sizeof(*f));

	f->refcount = 1; f->context = context; f->seqno = seqno; f->signaled = signaled; f->ops = &plain_ops;
	if (signaled)
		f->timestamp = ktime_get();
	live++;
	return f;
}
static bool dma_fence_is_signaled(struct dma_fence *f)
{
	struct dma_fence_array *a = to_dma_fence_array(f);
	unsigned i;

	if (!a)
		return f->signaled;
	for (i = 0; i < a->num_fences; i++)  /* signal_on_any = false: done when every child is */
		if (!dma_fence_is_signaled(a->fences[i]))
			return false;
	return true;
}
static bool dma_fence_is_later(struct dma_fence *f1, struct dma_fence *f2) { return f1->seqno > f2->seqno; }
static ktime_t dma_fence_timestamp(struct dma_fence *f) { return f->timestamp; }
static struct dma_fence stub = { .refcount = 1 << 30, .signaled = true, .ops = &plain_ops };
static struct dma_fence *dma_fence_get_stub(void) { return dma_fence_get(&stub); }
static struct dma_fence *dma_fence_allocate_private_stub_with_timestamp(ktime_t t)
{
	struct dma_fence *f = new_fence(dma_fence_context_alloc(1), 0, true);

	f->timestamp = t;
	return f;
}
/* Takes over the fences array and its references, as the kernel's does. */
static struct dma_fence_array *dma_fence_array_create(int n, struct dma_fence **fences, u64 context, unsigned seqno,
						      bool signal_on_any)
{
	struct dma_fence_array *a = calloc(1, sizeof(*a));

	(void)signal_on_any;
	a->base.refcount = 1; a->base.context = context; a->base.seqno = seqno; a->base.ops = &dma_fence_array_ops;
	a->num_fences = n; a->fences = fences;
	live++;
	return a;
}
static struct dma_fence *dma_fence_chain_walk(struct dma_fence *f) { dma_fence_put(f); return NULL; }  /* no chains */

/* include/linux/dma-fence-chain.h (android13-5.15) */
static inline struct dma_fence *
dma_fence_chain_contained(struct dma_fence *fence)
{
	struct dma_fence_chain *chain = to_dma_fence_chain(fence);

	return chain ? chain->fence : fence;
}

/* drivers/dma-buf/dma-fence-array.c (android13-5.15) */
struct dma_fence *dma_fence_array_first(struct dma_fence *head)
{
	struct dma_fence_array *array;

	if (!head)
		return NULL;

	array = to_dma_fence_array(head);
	if (!array)
		return head;

	if (!array->num_fences)
		return NULL;

	return array->fences[0];
}

struct dma_fence *dma_fence_array_next(struct dma_fence *head,
				       unsigned int index)
{
	struct dma_fence_array *array = to_dma_fence_array(head);

	if (!array || index >= array->num_fences)
		return NULL;

	return array->fences[index];
}

/* include/linux/dma-fence-unwrap.h + drivers/dma-buf/dma-fence-unwrap.c (android13-5.15) */
struct dma_fence_unwrap {
	struct dma_fence *chain;
	struct dma_fence *array;
	unsigned int index;
};

#define dma_fence_unwrap_for_each(fence, cursor, head)			\
	for (fence = dma_fence_unwrap_first(head, cursor); fence;	\
	     fence = dma_fence_unwrap_next(cursor))

static struct dma_fence *
__dma_fence_unwrap_array(struct dma_fence_unwrap *cursor)
{
	cursor->array = dma_fence_chain_contained(cursor->chain);
	cursor->index = 0;
	return dma_fence_array_first(cursor->array);
}

struct dma_fence *dma_fence_unwrap_first(struct dma_fence *head,
					 struct dma_fence_unwrap *cursor)
{
	cursor->chain = dma_fence_get(head);
	return __dma_fence_unwrap_array(cursor);
}

struct dma_fence *dma_fence_unwrap_next(struct dma_fence_unwrap *cursor)
{
	struct dma_fence *tmp;

	++cursor->index;
	tmp = dma_fence_array_next(cursor->array, cursor->index);
	if (tmp)
		return tmp;

	cursor->chain = dma_fence_chain_walk(cursor->chain);
	return __dma_fence_unwrap_array(cursor);
}

struct dma_fence *__dma_fence_unwrap_merge(unsigned int num_fences,
					   struct dma_fence **fences,
					   struct dma_fence_unwrap *iter)
{
	struct dma_fence_array *result;
	struct dma_fence *tmp, **array;
	ktime_t timestamp;
	unsigned int i;
	size_t count;

	count = 0;
	timestamp = ns_to_ktime(0);
	for (i = 0; i < num_fences; ++i) {
		dma_fence_unwrap_for_each(tmp, &iter[i], fences[i]) {
			if (!dma_fence_is_signaled(tmp)) {
				++count;
			} else {
				ktime_t t = dma_fence_timestamp(tmp);

				if (ktime_after(t, timestamp))
					timestamp = t;
			}
		}
	}

	if (count == 0)
		return dma_fence_allocate_private_stub_with_timestamp(timestamp);

	array = kmalloc_array(count, sizeof(*array), GFP_KERNEL);
	if (!array)
		return NULL;

	for (i = 0; i < num_fences; ++i)
		fences[i] = dma_fence_unwrap_first(fences[i], &iter[i]);

	count = 0;
	do {
		unsigned int sel;

restart:
		tmp = NULL;
		for (i = 0; i < num_fences; ++i) {
			struct dma_fence *next;

			while (fences[i] && dma_fence_is_signaled(fences[i]))
				fences[i] = dma_fence_unwrap_next(&iter[i]);

			next = fences[i];
			if (!next)
				continue;

			if (!tmp || tmp->context > next->context) {
				tmp = next;
				sel = i;

			} else if (tmp->context < next->context) {
				continue;

			} else if (dma_fence_is_later(tmp, next)) {
				fences[i] = dma_fence_unwrap_next(&iter[i]);
				goto restart;
			} else {
				fences[sel] = dma_fence_unwrap_next(&iter[sel]);
				goto restart;
			}
		}

		if (tmp) {
			array[count++] = dma_fence_get(tmp);
			fences[sel] = dma_fence_unwrap_next(&iter[sel]);
		}
	} while (tmp);

	if (count == 0) {
		tmp = dma_fence_allocate_private_stub_with_timestamp(ktime_get());
		goto return_tmp;
	}

	if (count == 1) {
		tmp = array[0];
		goto return_tmp;
	}

	result = dma_fence_array_create(count, array,
					dma_fence_context_alloc(1),
					1, false);
	if (!result) {
		for (i = 0; i < count; i++)
			dma_fence_put(array[i]);
		tmp = NULL;
		goto return_tmp;
	}
	return &result->base;

return_tmp:
	kfree(array);
	return tmp;
}

/* 5.15's dma_resv: one exclusive fence + shared fences; setting the exclusive one drops the shared ones. */
struct dma_resv { struct dma_fence *excl; struct dma_fence *shared[64]; unsigned n; };
static int dma_resv_get_fences(struct dma_resv *obj, struct dma_fence **excl, unsigned *count, struct dma_fence ***shared)
{
	unsigned i;

	*excl = dma_fence_get(obj->excl);
	*count = obj->n;
	*shared = NULL;
	if (obj->n) {
		*shared = malloc(obj->n * sizeof(**shared));
		for (i = 0; i < obj->n; i++)
			(*shared)[i] = dma_fence_get(obj->shared[i]);
	}
	return 0;
}
static void dma_resv_add_excl_fence(struct dma_resv *obj, struct dma_fence *f)
{
	unsigned i;

	dma_fence_get(f);
	dma_fence_put(obj->excl);
	for (i = 0; i < obj->n; i++)
		dma_fence_put(obj->shared[i]);
	obj->n = 0;
	obj->excl = f;
}

#include "resv_fence.inc"  /* the shipped dma_buf_resv_fence */

/* Depth of a fence's nesting: 0 = plain, 1 = flat array, ... */
static int nest(struct dma_fence *f)
{
	struct dma_fence_array *a = to_dma_fence_array(f);
	unsigned i;
	int d = 0, c;

	if (!a)
		return 0;
	for (i = 0; i < a->num_fences; i++)
		if ((c = nest(a->fences[i])) > d)
			d = c;
	return d + 1;
}

int main(int argc, char **argv)
{
	int frames = argc > 1 ? atoi(argv[1]) : 1000, i, ok = 1;
	struct dma_resv resv = {0};
	struct dma_fence *gpu[2] = {0}, *excl, *rd;
	const u64 ctx = dma_fence_context_alloc(1);  /* the GPU queue's context (KGSL): one seqno per frame */

	for (i = 1; i <= frames; i++) {
		struct dma_fence *frame = new_fence(ctx, i, false);

		/* IMPORT_SYNC_FILE(WRITE) = dma_buf_import_sync_file's write branch */
		if (dma_buf_resv_fence(&resv, true, frame, &excl)) { printf("FAIL: import returned an error at frame %d\n", i); return 1; }
		dma_resv_add_excl_fence(&resv, excl);
		dma_fence_put(excl);
		/* Xwayland: EXPORT_SYNC_FILE(READ) before its copy; it must wait for this frame */
		if (dma_buf_resv_fence(&resv, false, NULL, &rd)) { printf("FAIL: export returned an error at frame %d\n", i); return 1; }
		if (dma_fence_is_signaled(rd)) { printf("FAIL: frame %d: the exported fence is signaled before the frame's GPU work\n", i); ok = 0; }
		dma_fence_put(rd);
		/* the GPU finishes the frame before last (two in flight); Mesa drops its reference once it's done */
		if (gpu[0]) { gpu[0]->signaled = true; gpu[0]->timestamp = ktime_get(); dma_fence_put(gpu[0]); }
		gpu[0] = gpu[1]; gpu[1] = frame;
	}
	printf("after %d frames: the buffer's fence is nested %d deep\n", frames, nest(resv.excl));
	for (i = 0; i < 2; i++)
		if (gpu[i]) { gpu[i]->signaled = true; dma_fence_put(gpu[i]); }
	/* the game closes: its swapchain buffer goes, and with it the buffer's fences */
	dma_fence_put(resv.excl);
	printf("freeing the buffer: release recursion %ld deep, %ld fences leaked\n", max_depth, live);
	if (max_depth > 3) { printf("FAIL: release recursion grows with the frames shown (%ld for %d frames)\n", max_depth, frames); ok = 0; }
	if (live) { printf("FAIL: %ld fences leaked\n", live); ok = 0; }
	return !ok;
}

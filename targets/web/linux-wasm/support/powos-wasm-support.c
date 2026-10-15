// PowOS on Linux/Wasm: runtime support every C++ program links (libpowos-wasm-support.a, build-support.sh).
//
// A Wasm module can't leave a function undefined: whatever the linker doesn't resolve becomes an import, and the
// runtime then fails to load the program ("function import requires a callable"). These are the symbols C++ code
// (Qt) references that neither musl nor our exceptions-off libc++abi defines.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void die(const char *what)
{
	static const char msg[] = "PowOS/Wasm: C++ exception thrown, but exceptions are not supported here: ";
	write(2, msg, sizeof msg - 1);
	write(2, what, __builtin_strlen(what));
	write(2, "\n", 1);
	abort();
}

// HACK: exceptions. libc++/libc++abi are built without exception support (build-libcxx.sh) and Qt with
// FEATURE_exceptions=OFF, but a few sources still reference the throw path. A throw here is fatal - the same outcome
// as an uncaught exception. Real fix: Wasm exception handling (-fwasm-exceptions) in libc++abi and the runtime.
void *__cxa_allocate_exception(unsigned long size) { die("__cxa_allocate_exception"); return 0; }
void __cxa_throw(void *obj, void *type, void (*dtor)(void *)) { die("__cxa_throw"); }
void *__cxa_current_exception_type(void) { return 0; } // no exception is ever in flight

// thread_local destructors: libc++abi's __cxa_thread_atexit calls this (glibc's interface; musl has none). Run them
// when the thread exits, via a pthread key; the main thread's run at exit().
struct tl_dtor {
	void (*fn)(void *);
	void *obj;
	struct tl_dtor *next;
};
static pthread_key_t tl_key;
static pthread_once_t tl_once = PTHREAD_ONCE_INIT;
static __thread struct tl_dtor *tl_list;

static void tl_run(void *unused)
{
	while (tl_list) {
		struct tl_dtor *d = tl_list;
		tl_list = d->next;
		d->fn(d->obj);
		free(d);
	}
}

static void tl_run_main(void) { tl_run(0); }

static void tl_init(void)
{
	pthread_key_create(&tl_key, tl_run);
	atexit(tl_run_main);
}

int __cxa_thread_atexit_impl(void (*fn)(void *), void *obj, void *dso)
{
	struct tl_dtor *d = malloc(sizeof *d);
	if (!d)
		return -1;
	pthread_once(&tl_once, tl_init);
	d->fn = fn;
	d->obj = obj;
	d->next = tl_list;
	tl_list = d;
	pthread_setspecific(tl_key, (void *)1); // non-NULL, so the key's destructor runs at thread exit
	return 0;
}

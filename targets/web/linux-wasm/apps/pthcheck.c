// PowOS on Linux/Wasm: do POSIX threads work? (each thread is a clone()d task - a Web Worker running a new instance of
// this program on the shared memory). Prints PTHCHECK OK when two threads ran and the main thread got past the joins.
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

static void *work(void *arg)
{
	long n = (long)arg, s = 0;
	for (long i = 0; i < 1000000; i++)
		s += (i ^ n) & 7;
	printf("pthcheck: thread %ld self %p tls %p sum %ld\n", n, (void *)pthread_self(), __builtin_wasm_tls_base(), s);
	fflush(stdout);
	return (void *)s;
}

int main(int argc, char **argv)
{
	pthread_t t[2];
	void *r[2];
	printf("pthcheck: main self %p tls %p\n", (void *)pthread_self(), __builtin_wasm_tls_base());
	fflush(stdout);
	for (long i = 0; i < 2; i++)
		if (pthread_create(&t[i], 0, work, (void *)i)) {
			printf("pthcheck: pthread_create failed\n");
			return 1;
		}
	for (int i = 0; i < 2; i++)
		pthread_join(t[i], &r[i]);
	printf("pthcheck: joined %ld %ld\n", (long)r[0], (long)r[1]);
	printf("%s\n", (long)r[0] == 3500000 && (long)r[1] == 3500000 ? "PTHCHECK OK" : "PTHCHECK FAILED");
	return 0;
}

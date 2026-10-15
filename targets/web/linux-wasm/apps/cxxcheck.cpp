// PowOS on Linux/Wasm: does C++ work? libc++ strings, containers, algorithms, iostreams, chrono and std::thread
// (threads are clone()d tasks - each its own Web Worker). Prints CXXCHECK OK when everything adds up.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <iostream>
#include <unistd.h>
#include <map>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

int main(int argc, char **argv)
{
	// Before any thread: separates "C++ output is broken" from "threads broke the output".
	printf("cxxcheck: printf works\n");
	fflush(stdout);
	std::cout << "cxxcheck: std::cout works" << std::endl;

	std::vector<int> v(1000);
	std::iota(v.begin(), v.end(), 1);
	std::reverse(v.begin(), v.end());
	std::sort(v.begin(), v.end());
	long sum = std::accumulate(v.begin(), v.end(), 0L);

	std::map<std::string, int> m{{"powos", 1}, {"wasm", 2}, {"linux", 3}};
	std::string keys;
	for (auto &[k, val] : m)
		keys += k + "=" + std::to_string(val) + " ";

	std::atomic<long> total{0};
	auto t0 = std::chrono::steady_clock::now();
	std::vector<std::thread> threads;
	for (int t = 0; t < 4; t++)
		threads.emplace_back([&total, t] {
			long s = 0;
			for (long i = 0; i < 2000000; i++)
				s += (i ^ t) & 7;
			total += s;
		});
	for (auto &th : threads)
		th.join();
	auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
	// After the threads: which output paths still work (each thread is a new Wasm instance of this program).
	write(1, "cxxcheck: write() after threads\n", 32);
	printf("cxxcheck: printf after threads\n");
	fflush(stdout);
	std::cerr << "cxxcheck: std::cerr after threads" << std::endl;

	std::cout << "sum " << sum << " keys " << keys << "threads " << total << " in " << ms << " ms" << std::endl;
	bool ok = sum == 500500 && m.size() == 3 && total == 4 * 7000000L;
	std::cout << (ok ? "CXXCHECK OK" : "CXXCHECK FAILED") << std::endl;
	return ok ? 0 : 1;
}

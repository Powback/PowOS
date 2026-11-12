/* loader.exe <mono.dll> <Managed dir> <etc dir> <mono args...>: the game's own Mono as a command-line mono.
 * Legacy Unity ships mono.dll (embedder API) but no mono.exe; mono_main is exported and holds the --aot driver. */
#include <windows.h>
#include <stdio.h>
typedef int (*main_t)(int, char **);
typedef void (*dirs_t)(const char *, const char *);
typedef void (*path_t)(const char *);
int main(int argc, char **argv) {
  if (argc < 5) { fprintf(stderr, "usage: loader mono.dll managed etc mono-args...\n"); return 2; }
  HMODULE m = LoadLibraryA(argv[1]);
  if (!m) { fprintf(stderr, "LoadLibrary %s failed %lu\n", argv[1], GetLastError()); return 3; }
  dirs_t sd = (dirs_t)GetProcAddress(m, "mono_set_dirs");
  path_t sp = (path_t)GetProcAddress(m, "mono_set_assemblies_path");
  main_t mm = (main_t)GetProcAddress(m, "mono_main");
  if (!sd || !sp || !mm) { fprintf(stderr, "mono.dll lacks mono_set_dirs/mono_set_assemblies_path/mono_main\n"); return 4; }
  sd(argv[2], argv[3]);
  sp(argv[2]);
  argv[3] = "mono";
  return mm(argc - 3, argv + 3);
}

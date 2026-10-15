#!/bin/bash
# Prints the CMake toolchain file for PowOS programs on Linux/Wasm (wasm32 NOMMU, musl, static libc++) - used for Qt
# (build-qt.sh) and everything built against it. Same flags as build-apps.sh:
# - clang through upstream's fake-llvm wrapper (adds the Wasm linker flags whenever it sees a -l);
# - -D__USE_TIME_BITS64 so the kernel's input_event matches musl's 64-bit time_t;
# - programs link as -pie (not -shared: a shared library imports every weak symbol it defines - all C++ inline code);
# - libraries in CMAKE_*_STANDARD_LIBRARIES so they come after the objects (static archives are searched in order).
cat <<'EOF'
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR wasm32)
set(CMAKE_SYSROOT /ws/install/musl-wasm32_nommu)
set(CMAKE_C_COMPILER /linux-wasm/tools/fake-llvm/clang)
set(CMAKE_CXX_COMPILER /linux-wasm/tools/fake-llvm/clang)
set(CMAKE_AR /ws/install/llvm/bin/llvm-ar)
set(CMAKE_RANLIB /ws/install/llvm/bin/llvm-ranlib)
set(CMAKE_NM /ws/install/llvm/bin/llvm-nm)
set(CMAKE_OBJCOPY /ws/install/llvm/bin/llvm-objcopy)
set(CMAKE_STRIP /ws/install/llvm/bin/llvm-strip)
set(ENV{REAL_LLVM} /ws/install/llvm/bin)
set(POWOS_WASM_FLAGS "--target=wasm-linux-musl -march=wasm32 -isystem /ws/install/busybox-kernel-headers-wasm32_nommu -D__USE_TIME_BITS64 -fPIC")
set(CMAKE_C_FLAGS_INIT "${POWOS_WASM_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${POWOS_WASM_FLAGS} -nostdinc++ -isystem /ws/install/libcxx-wasm32_nommu/include/c++/v1")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-Wl,-pie -Wl,--import-table -L/ws/install/libcxx-wasm32_nommu/lib")
set(CMAKE_C_STANDARD_LIBRARIES "-lc --rtlib=compiler-rt")
set(CMAKE_CXX_STANDARD_LIBRARIES "-lc++ -lc++abi -lpowos-wasm-support -lc --rtlib=compiler-rt")
set(CMAKE_FIND_ROOT_PATH /ws/install/musl-wasm32_nommu /ws/install/libcxx-wasm32_nommu /ws/install/qt-wasm32_nommu)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

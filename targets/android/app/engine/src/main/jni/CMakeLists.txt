cmake_minimum_required(VERSION 3.18)
project(andromarchy_consumer C)

set(ANDROMARCHY_CORE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/andromarchy_core)

add_library(andromarchy_consumer SHARED
    native_consumer.c
    direct_scanout.c
    native_audio.c
    camera_service.c
    ${ANDROMARCHY_CORE_DIR}/libdisplay_consumer/display_consumer.c
    ${ANDROMARCHY_CORE_DIR}/common/socket_utils.c
)

target_include_directories(andromarchy_consumer PRIVATE
    ${ANDROMARCHY_CORE_DIR}/libdisplay_consumer
    ${ANDROMARCHY_CORE_DIR}/common
)

target_compile_options(andromarchy_consumer PRIVATE -O3 -flto)
target_link_options(andromarchy_consumer PRIVATE -flto -fuse-ld=lld)

target_link_libraries(andromarchy_consumer
    android
    nativewindow
    log
    dl
    aaudio
    camera2ndk
    mediandk
)

# Root helper for "connect with root" mode. Built as an executable but named
# lib*.so so the Android packager extracts it into the app's nativeLibraryDir
# with execute permission (requires useLegacyPackaging=true). Launched by the
# app via `su -c` to connect the daemon socket and pass the fd back.
add_executable(fdhelper
    fd_helper.c
    ${ANDROMARCHY_CORE_DIR}/common/socket_utils.c
)

target_include_directories(fdhelper PRIVATE
    ${ANDROMARCHY_CORE_DIR}/common
)

set_target_properties(fdhelper PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "fdhelper"
    SUFFIX ".so"
)

target_link_libraries(fdhelper log)

# Built/staged by sources/powstream/build-android.sh before the APK pipeline.
set(POWSTREAM_STAGE ${CMAKE_CURRENT_SOURCE_DIR}/../../../powstream-native)
if(NOT EXISTS ${POWSTREAM_STAGE}/include/powstream_client_core.h)
    message(FATAL_ERROR "Run sources/powstream/build-android.sh before native/APK builds")
endif()
file(STRINGS ${POWSTREAM_STAGE}/include/powstream-source-revision POWSTREAM_REV)
if(NOT POWSTREAM_REV STREQUAL "42dd13d79b35056dcabeb1fae4cd56f4cc5c0eae")
    message(FATAL_ERROR "PowStream staging revision does not match the Android source pin")
endif()
add_library(powstream_client_core SHARED IMPORTED)
set_target_properties(powstream_client_core PROPERTIES IMPORTED_LOCATION
    ${POWSTREAM_STAGE}/${ANDROID_ABI}/libpowstream_client_core.so)
add_library(powstream_jni SHARED powstream_jni.c)
target_include_directories(powstream_jni PRIVATE ${POWSTREAM_STAGE}/include)
target_compile_options(powstream_jni PRIVATE -Wall -Wextra -Werror)
target_link_options(powstream_jni PRIVATE -Wl,-z,max-page-size=16384)
target_link_libraries(powstream_jni powstream_client_core)

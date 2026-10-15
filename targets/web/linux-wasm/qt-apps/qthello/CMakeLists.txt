cmake_minimum_required(VERSION 3.21)
project(qthello LANGUAGES CXX)
find_package(Qt6 REQUIRED COMPONENTS Widgets)
qt_standard_project_setup()
qt_add_executable(qthello main.cpp)
target_link_libraries(qthello PRIVATE Qt6::Widgets)
# Static Qt: the platform (linuxfb) and input (evdev) plugins are linked in, not loaded.
qt_import_plugins(qthello
  INCLUDE Qt6::QLinuxFbIntegrationPlugin Qt6::QEvdevKeyboardPlugin Qt6::QEvdevMousePlugin
  EXCLUDE_BY_TYPE imageformats)

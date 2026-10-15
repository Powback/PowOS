cmake_minimum_required(VERSION 3.21)
project(qmlhello LANGUAGES CXX)
find_package(Qt6 REQUIRED COMPONENTS Quick)
qt_standard_project_setup(REQUIRES 6.8)
qt_add_executable(qmlhello main.cpp)
qt_add_qml_module(qmlhello URI PowOS.Hello VERSION 1.0 QML_FILES Main.qml)
target_link_libraries(qmlhello PRIVATE Qt6::Quick)
# Static Qt: platform/input plugins and the QML modules Main.qml imports are linked in, not loaded.
qt_import_plugins(qmlhello
  INCLUDE Qt6::QLinuxFbIntegrationPlugin Qt6::QEvdevKeyboardPlugin Qt6::QEvdevMousePlugin
  EXCLUDE_BY_TYPE imageformats)
qt_import_qml_plugins(qmlhello)

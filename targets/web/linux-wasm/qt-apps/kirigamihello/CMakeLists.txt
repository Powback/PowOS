cmake_minimum_required(VERSION 3.21)
project(kirigamihello LANGUAGES CXX)
find_package(Qt6 REQUIRED COMPONENTS Quick QuickControls2)
find_package(KF6Kirigami REQUIRED)
qt_standard_project_setup(REQUIRES 6.8)
qt_add_executable(kirigamihello main.cpp)
qt_add_qml_module(kirigamihello URI PowOS.KirigamiHello VERSION 1.0 QML_FILES Main.qml)
target_link_libraries(kirigamihello PRIVATE Qt6::Quick Qt6::QuickControls2 KF6::Kirigami)
# Static Qt + Kirigami: platform/input plugins and every QML module Main.qml imports are linked in.
qt_import_plugins(kirigamihello
  INCLUDE Qt6::QLinuxFbIntegrationPlugin Qt6::QEvdevKeyboardPlugin Qt6::QEvdevMousePlugin
  EXCLUDE_BY_TYPE imageformats)
qt_import_qml_plugins(kirigamihello)

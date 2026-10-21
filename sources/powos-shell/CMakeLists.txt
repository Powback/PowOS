# powos-shell: the PowOS desktop shell's native host (docs/DESKTOP-WEB-SHELL.md §3). Qt 6 + KF6; the UI is shell/,
# served on powos://shell/ into QtWebEngine views that LayerShellQt makes Wayland layer surfaces.
cmake_minimum_required(VERSION 3.22)
project(powos-shell VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
include(GNUInstallDirs)

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui Widgets WebEngineCore WebEngineWidgets WebChannel Network)
find_package(KF6Service REQUIRED)
find_package(KF6KIO REQUIRED)
find_package(KF6WindowSystem REQUIRED)
find_package(LayerShellQt REQUIRED)
# libtaskmanager (plasma-workspace-devel): no ABI promise - built in the image against the image's Plasma.
find_package(LibTaskManager REQUIRED)

add_executable(powos-shell
  src/main.cpp
  src/view.cpp
  src/home.cpp
  src/panel.cpp
  src/server.cpp
  src/bridge.cpp
  src/services.cpp
  src/net.cpp
)
target_link_libraries(powos-shell PRIVATE
  Qt6::Widgets Qt6::Network Qt6::WebEngineCore Qt6::WebEngineWidgets Qt6::WebChannel
  KF6::Service KF6::KIOGui KF6::WindowSystem
  LayerShellQt::Interface
  PW::LibTaskManager
)

install(TARGETS powos-shell RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
# KWin grants the restricted Wayland interfaces by this file, matched on Exec's full path (§3.3).
install(FILES org.powos.shell.desktop DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
# The desktop home's switch (start|stop|status), next to the binary it runs.
install(PROGRAMS powos-desktop-shell DESTINATION ${CMAKE_INSTALL_BINDIR})

# The web UI itself (shell/ of the repo), as the base the override folder (~/.config/powos/shell) sits over.
set(POWOS_SHELL_WEB "" CACHE PATH "shell/ to install to share/powos/shell (empty: not installed)")
set(POWOS_SHELL_WEB_DEST "${CMAKE_INSTALL_DATADIR}/powos/shell" CACHE STRING "where shell/ goes under the prefix")
if(POWOS_SHELL_WEB)
  install(DIRECTORY ${POWOS_SHELL_WEB}/ DESTINATION ${POWOS_SHELL_WEB_DEST}
          PATTERN node_modules EXCLUDE)
endif()

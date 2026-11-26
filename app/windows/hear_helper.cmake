# ownsemble_hear.exe, the helper process for "Hear the words" (plan 10
# I2i5), compiled from helper/ownsemble_hear.dart with the Flutter SDK's
# own dart (`dart compile exe`) and installed beside ownsemble.exe, in every
# build configuration, so a debug or test build never runs a missing or old
# helper. It is rebuilt when any Dart file of lib/ or helper/, the package
# lock or the SDK changes (a listed set: the DEPFILE option needs CMake
# 3.21 with Visual Studio, this project declares 3.14).

# FLUTTER_ROOT is set in the flutter subdirectory's scope only; read the
# generated file here, inside a function so its PARENT_SCOPE lines have a
# parent.
function(ownsemble_read_flutter_root OUT)
  include("${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/generated_config.cmake")
  set(${OUT} "${FLUTTER_ROOT}" PARENT_SCOPE)
endfunction()
ownsemble_read_flutter_root(HEAR_FLUTTER_ROOT)

set(HEAR_APP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(HEAR_DART "${HEAR_FLUTTER_ROOT}/bin/cache/dart-sdk/bin/dart.exe")
set(HEAR_HELPER_EXE "${CMAKE_BINARY_DIR}/hear_helper/ownsemble_hear.exe")
if(NOT EXISTS "${HEAR_DART}")
  message(FATAL_ERROR "No dart.exe at ${HEAR_DART} for ownsemble_hear.exe")
endif()

file(GLOB_RECURSE HEAR_HELPER_SOURCES CONFIGURE_DEPENDS
  "${HEAR_APP_DIR}/lib/*.dart"
  "${HEAR_APP_DIR}/helper/*.dart")

add_custom_command(
  OUTPUT "${HEAR_HELPER_EXE}"
  COMMAND "${HEAR_DART}" compile exe helper/ownsemble_hear.dart
    -o "${HEAR_HELPER_EXE}"
  WORKING_DIRECTORY "${HEAR_APP_DIR}"
  DEPENDS ${HEAR_HELPER_SOURCES}
    "${HEAR_APP_DIR}/pubspec.lock"
    "${HEAR_APP_DIR}/.dart_tool/package_config.json"
    "${HEAR_DART}"
  COMMENT "Compiling ownsemble_hear.exe"
  VERBATIM)
add_custom_target(ownsemble_hear ALL DEPENDS "${HEAR_HELPER_EXE}")
add_dependencies(${BINARY_NAME} ownsemble_hear)

install(PROGRAMS "${HEAR_HELPER_EXE}" DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

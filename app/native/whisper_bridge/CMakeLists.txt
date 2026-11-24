# ownsemble_whisper: the bridge to whisper.cpp 1.9.5 (plan 10 I2d).
#
# Built by the Windows app (windows/CMakeLists.txt adds this folder) and on
# its own for the check tools:
#   cmake -S native/whisper_bridge -B <dir> && cmake --build <dir> --config Release
# It links no whisper.cpp library: those come with the downloaded model
# bundle and are opened at run time. Only whisper.cpp's pinned headers are
# needed (whisper.cpp-1.9.5/, MIT, copied from the release tarball).
cmake_minimum_required(VERSION 3.14)
project(ownsemble_whisper LANGUAGES C)

# The app's CMakeLists copies the Release flags into its Profile mode before
# C is enabled (Codex review), so the C ones arrive empty; take them now.
if(NOT CMAKE_C_FLAGS_PROFILE)
  set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
endif()

add_library(ownsemble_whisper SHARED whisper_bridge.c)
target_include_directories(ownsemble_whisper PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/whisper.cpp-1.9.5/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/whisper.cpp-1.9.5/ggml/include")
set_target_properties(ownsemble_whisper PROPERTIES C_VISIBILITY_PRESET hidden)
if(MSVC)
  target_compile_options(ownsemble_whisper PRIVATE /W4 /WX /utf-8)
  # vsnprintf, fopen and the like without the _s suffix.
  target_compile_definitions(ownsemble_whisper PRIVATE
    _CRT_SECURE_NO_WARNINGS)
  # The VC++ runtime DLL, as ownsemble.exe and whisper.cpp already need.
else()
  target_compile_options(ownsemble_whisper PRIVATE -Wall -Wextra -Werror)
  target_link_libraries(ownsemble_whisper PRIVATE dl pthread m)
endif()

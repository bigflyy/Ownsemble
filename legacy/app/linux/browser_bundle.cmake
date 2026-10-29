# Keep CEF's compiler flags and wrapper out of Flutter/plugin configuration.
include(ExternalProject)
if(DEFINED ENV{OWNSEMBLE_CEF_ROOT} AND NOT "$ENV{OWNSEMBLE_CEF_ROOT}" STREQUAL "")
  # Explicit verified SDK selection must also work in an existing build tree.
  set(CEF_ROOT "$ENV{OWNSEMBLE_CEF_ROOT}" CACHE PATH "Verified pinned CEF SDK" FORCE)
else()
  set(CEF_ROOT "" CACHE PATH "Verified pinned CEF SDK")
endif()
if(CEF_ROOT)
  if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
    message(FATAL_ERROR "The pinned browser runtime currently supports Linux x64")
  endif()
  ExternalProject_Add(ownsemble_browser_native
    SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/browser"
    BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/browser_native"
    CMAKE_ARGS "-DCEF_ROOT=${CEF_ROOT}" -DCMAKE_BUILD_TYPE=Release
    BUILD_ALWAYS TRUE
    BUILD_COMMAND "${CMAKE_COMMAND}" --build <BINARY_DIR> --parallel 4
    INSTALL_COMMAND "")
  add_dependencies(${BINARY_NAME} ownsemble_browser_native)
  install(CODE "
    execute_process(COMMAND \"${CMAKE_COMMAND}\" --install
      \"${CMAKE_CURRENT_BINARY_DIR}/browser_native\" --prefix \"${CMAKE_INSTALL_PREFIX}\"
      RESULT_VARIABLE browser_install_result)
    if(NOT browser_install_result EQUAL 0)
      message(FATAL_ERROR \"Native browser bundle installation failed\")
    endif()
    " COMPONENT Runtime)
else()
  message(STATUS "CEF SDK not selected: Linux browser capabilities will fail closed")
endif()

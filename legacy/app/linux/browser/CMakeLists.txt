cmake_minimum_required(VERSION 3.21)
project(ownsemble_browser C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} wrapper)
add_executable(ownsemble_browser browser_main.cc)
target_include_directories(ownsemble_browser PRIVATE ${CEF_ROOT})
target_link_libraries(ownsemble_browser PRIVATE libcef_dll_wrapper "${CEF_ROOT}/Release/libcef.so" pthread dl)
set_target_properties(ownsemble_browser PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "$ORIGIN")

add_executable(ownsemble_process_security_test process_security_test.cc)
target_compile_options(ownsemble_process_security_test PRIVATE -UNDEBUG -Wall -Wextra -Werror)
enable_testing()
add_test(NAME process_security COMMAND ownsemble_process_security_test)

# Only the generated bundle receives copies. Never modify the source SDK.
set(BROWSER_DESTINATION "lib/ownsemble_browser")
install(TARGETS ownsemble_browser RUNTIME DESTINATION "${BROWSER_DESTINATION}")
install(DIRECTORY "${CEF_ROOT}/Release/" DESTINATION "${BROWSER_DESTINATION}"
  PATTERN "chrome-sandbox" EXCLUDE)
install(DIRECTORY "${CEF_ROOT}/Resources/" DESTINATION "${BROWSER_DESTINATION}")
install(FILES "${CEF_ROOT}/LICENSE.txt" "${CMAKE_CURRENT_SOURCE_DIR}/cef-runtime.json"
  DESTINATION "${BROWSER_DESTINATION}")
# Refuse to label a different SDK as the pinned tested runtime.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/cef-runtime.json" CEF_RUNTIME_PIN)
string(JSON EXPECTED_CEF_VERSION GET "${CEF_RUNTIME_PIN}" cef_version)
file(STRINGS "${CEF_ROOT}/include/cef_version.h" ACTUAL_CEF_VERSION REGEX "^#define CEF_VERSION ")
if(NOT ACTUAL_CEF_VERSION STREQUAL "#define CEF_VERSION \"${EXPECTED_CEF_VERSION}\"")
  message(FATAL_ERROR "CEF SDK does not match cef-runtime.json; prepare the pinned SDK")
endif()

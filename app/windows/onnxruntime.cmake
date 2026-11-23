# ONNX Runtime for "Fit to this recording" (plan 10 G2a).
#
# The lyrics aligner runs its model through Microsoft's onnxruntime.dll,
# loaded by lib/lyrics/onnx_runtime.dart only when the user fits lyrics.
# The DLL is not kept in git: on the first configure on a PC this downloads
# Microsoft's NuGet package (about 160 MB), checks its SHA-256, takes the
# CPU DLL and its license files out of it, checks those too and deletes the
# package. The three files (17 MB) stay in a cache outside the build folder
# (%LOCALAPPDATA%\ownsemble-build), so a clean build downloads nothing.
# Only commands of CMake 3.14, the version this project declares.

set(ONNXRUNTIME_VERSION "1.31.1")
set(ONNXRUNTIME_NUPKG_SHA256
  "6871ccbc97f3d5bdb4095a1dcec33aa78d56f6ed8de5980ef5fa1d9f2e7c679a")
set(ONNXRUNTIME_DLL_SHA256
  "cb2fa518b18356617f6f9f460c012501da2819ec7e5c1d80bd8f5de20492db0c")
set(ONNXRUNTIME_LICENSE_SHA256
  "c250d6278f0b47a6439fb7592b08b58a55eb9f535aa49a1db63211c3f982b674")
set(ONNXRUNTIME_NOTICES_SHA256
  "c53a76501ef60db6f865f20599f220761201ac4057683acefdab37d861b86622")

if(DEFINED ENV{LOCALAPPDATA})
  file(TO_CMAKE_PATH "$ENV{LOCALAPPDATA}/ownsemble-build" ONNXRUNTIME_CACHE)
else()
  set(ONNXRUNTIME_CACHE "${CMAKE_BINARY_DIR}")
endif()
set(ONNXRUNTIME_DIR "${ONNXRUNTIME_CACHE}/onnxruntime-${ONNXRUNTIME_VERSION}")
set(ONNXRUNTIME_DLL "${ONNXRUNTIME_DIR}/onnxruntime.dll")
set(ONNXRUNTIME_LICENSE "${ONNXRUNTIME_DIR}/LICENSE")
set(ONNXRUNTIME_NOTICES "${ONNXRUNTIME_DIR}/ThirdPartyNotices.txt")

# Whether FILE exists and has the SHA-256 in EXPECTED; sets OUT to TRUE/FALSE.
function(onnxruntime_file_ok FILE EXPECTED OUT)
  set(${OUT} FALSE PARENT_SCOPE)
  if(EXISTS "${FILE}")
    file(SHA256 "${FILE}" ACTUAL)
    if(ACTUAL STREQUAL EXPECTED)
      set(${OUT} TRUE PARENT_SCOPE)
    endif()
  endif()
endfunction()

onnxruntime_file_ok("${ONNXRUNTIME_DLL}" "${ONNXRUNTIME_DLL_SHA256}" DLL_OK)
onnxruntime_file_ok("${ONNXRUNTIME_LICENSE}" "${ONNXRUNTIME_LICENSE_SHA256}"
  LICENSE_OK)
onnxruntime_file_ok("${ONNXRUNTIME_NOTICES}" "${ONNXRUNTIME_NOTICES_SHA256}"
  NOTICES_OK)

if(NOT (DLL_OK AND LICENSE_OK AND NOTICES_OK))
  set(NUPKG "${ONNXRUNTIME_DIR}/microsoft.ml.onnxruntime.${ONNXRUNTIME_VERSION}.nupkg")
  message(STATUS "Downloading ONNX Runtime ${ONNXRUNTIME_VERSION} from NuGet")
  # An earlier, complete download with the right hash is not fetched again.
  file(DOWNLOAD
    "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/${ONNXRUNTIME_VERSION}/microsoft.ml.onnxruntime.${ONNXRUNTIME_VERSION}.nupkg"
    "${NUPKG}"
    EXPECTED_HASH SHA256=${ONNXRUNTIME_NUPKG_SHA256}
    TLS_VERIFY ON
    SHOW_PROGRESS)
  set(UNPACKED "${ONNXRUNTIME_DIR}/unpacked")
  file(REMOVE_RECURSE "${UNPACKED}")
  file(MAKE_DIRECTORY "${UNPACKED}")
  # A .nupkg is a zip; "cmake -E tar" reads zips and takes named members.
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar xf "${NUPKG}"
      "runtimes/win-x64/native/onnxruntime.dll" "LICENSE"
      "ThirdPartyNotices.txt"
    WORKING_DIRECTORY "${UNPACKED}"
    RESULT_VARIABLE UNPACK_RESULT)
  if(NOT UNPACK_RESULT EQUAL 0)
    message(FATAL_ERROR "Could not unpack ${NUPKG}: ${UNPACK_RESULT}")
  endif()
  # file(COPY) skips a target with the same time stamp: a damaged cached
  # file must really be replaced (Codex review).
  file(REMOVE "${ONNXRUNTIME_DLL}" "${ONNXRUNTIME_LICENSE}"
    "${ONNXRUNTIME_NOTICES}")
  file(COPY "${UNPACKED}/runtimes/win-x64/native/onnxruntime.dll"
    "${UNPACKED}/LICENSE" "${UNPACKED}/ThirdPartyNotices.txt"
    DESTINATION "${ONNXRUNTIME_DIR}")
  file(REMOVE_RECURSE "${UNPACKED}")
  file(REMOVE "${NUPKG}")
  onnxruntime_file_ok("${ONNXRUNTIME_DLL}" "${ONNXRUNTIME_DLL_SHA256}" DLL_OK)
  onnxruntime_file_ok("${ONNXRUNTIME_LICENSE}" "${ONNXRUNTIME_LICENSE_SHA256}"
    LICENSE_OK)
  onnxruntime_file_ok("${ONNXRUNTIME_NOTICES}" "${ONNXRUNTIME_NOTICES_SHA256}"
    NOTICES_OK)
  if(NOT (DLL_OK AND LICENSE_OK AND NOTICES_OK))
    message(FATAL_ERROR "ONNX Runtime files from NuGet have unexpected hashes")
  endif()
endif()

# Beside ownsemble.exe; the license files named so they say whose they are.
install(FILES "${ONNXRUNTIME_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
install(FILES "${ONNXRUNTIME_LICENSE}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  RENAME "onnxruntime-LICENSE.txt" COMPONENT Runtime)
install(FILES "${ONNXRUNTIME_NOTICES}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  RENAME "onnxruntime-ThirdPartyNotices.txt" COMPONENT Runtime)

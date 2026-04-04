# Install script for directory: C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "C:/Program Files (x86)/Ollama")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "Release")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "FALSE")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/ml/backend/ggml/ggml/src/cmake_install.cmake")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "CPU" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "C:/Program Files (x86)/Ollama/lib/ollama/sycl/libggml-base.dll")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "C:/Program Files (x86)/Ollama/lib/ollama/sycl" TYPE SHARED_LIBRARY FILES "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/libggml-base.dll")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "CPU" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "C:/Program Files (x86)/Ollama/lib/ollama/sycl/ggml-cpu-alderlake.dll")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "C:/Program Files (x86)/Ollama/lib/ollama/sycl" TYPE MODULE FILES "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-alderlake.dll")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "CPU" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "C:/Program Files (x86)/Ollama/lib/ollama/sycl/ggml-cpu-haswell.dll")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "C:/Program Files (x86)/Ollama/lib/ollama/sycl" TYPE MODULE FILES "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-haswell.dll")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "CPU" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "C:/Program Files (x86)/Ollama/lib/ollama/sycl/ggml-cpu-icelake.dll")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "C:/Program Files (x86)/Ollama/lib/ollama/sycl" TYPE MODULE FILES "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-icelake.dll")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "CPU" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "C:/Program Files (x86)/Ollama/lib/ollama/sycl/ggml-cpu-sandybridge.dll")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "C:/Program Files (x86)/Ollama/lib/ollama/sycl" TYPE MODULE FILES "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-sandybridge.dll")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "CPU" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "C:/Program Files (x86)/Ollama/lib/ollama/sycl/ggml-cpu-skylakex.dll")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "C:/Program Files (x86)/Ollama/lib/ollama/sycl" TYPE MODULE FILES "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-skylakex.dll")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "CPU" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "C:/Program Files (x86)/Ollama/lib/ollama/sycl/ggml-cpu-sse42.dll")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "C:/Program Files (x86)/Ollama/lib/ollama/sycl" TYPE MODULE FILES "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-sse42.dll")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "CPU" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "C:/Program Files (x86)/Ollama/lib/ollama/sycl/ggml-cpu-x64.dll")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "C:/Program Files (x86)/Ollama/lib/ollama/sycl" TYPE MODULE FILES "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-x64.dll")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "CPU" OR NOT CMAKE_INSTALL_COMPONENT)
  file(GET_RUNTIME_DEPENDENCIES
    RESOLVED_DEPENDENCIES_VAR _CMAKE_DEPS
    LIBRARIES
      "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/libggml-base.dll"
    MODULES
      "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-alderlake.dll"
      "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-haswell.dll"
      "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-icelake.dll"
      "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-sandybridge.dll"
      "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-skylakex.dll"
      "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-sse42.dll"
      "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/ggml-cpu-x64.dll"
    PRE_EXCLUDE_REGEXES
      ".*"
    POST_EXCLUDE_FILES_STRICT
      "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/lib/ollama/libggml-base.dll"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "CPU" OR NOT CMAKE_INSTALL_COMPONENT)
  foreach(_CMAKE_TMP_dep IN LISTS _CMAKE_DEPS)
    foreach(_cmake_abs_file IN LISTS _CMAKE_TMP_dep)
      get_filename_component(_cmake_abs_file_name "${_cmake_abs_file}" NAME)
      list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES "C:/Program Files (x86)/Ollama/lib/ollama/sycl/${_cmake_abs_file_name}")
    endforeach()
    unset(_cmake_abs_file_name)
    unset(_cmake_abs_file)
    if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
      message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
    endif()
    if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
      message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
    endif()
    file(INSTALL DESTINATION "C:/Program Files (x86)/Ollama/lib/ollama/sycl" TYPE SHARED_LIBRARY FILES ${_CMAKE_TMP_dep}
      FOLLOW_SYMLINK_CHAIN)
  endforeach()
endif()

string(REPLACE ";" "\n" CMAKE_INSTALL_MANIFEST_CONTENT
       "${CMAKE_INSTALL_MANIFEST_FILES}")
if(CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/install_local_manifest.txt"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()
if(CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_COMPONENT MATCHES "^[a-zA-Z0-9_.+-]+$")
    set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INSTALL_COMPONENT}.txt")
  else()
    string(MD5 CMAKE_INST_COMP_HASH "${CMAKE_INSTALL_COMPONENT}")
    set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INST_COMP_HASH}.txt")
    unset(CMAKE_INST_COMP_HASH)
  endif()
else()
  set(CMAKE_INSTALL_MANIFEST "install_manifest.txt")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "C:/Users/Administrator/Documents/GitHub/ipex-llm/_build/ollama-ipex-latest/src/ollama/ollama-ollama-4589fa2/build-sycl/${CMAKE_INSTALL_MANIFEST}"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()

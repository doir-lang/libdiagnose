cmake_minimum_required(VERSION 3.21)
project(libdiagnose CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_subdirectory(nowide)

add_library(diagnose INTERFACE)
target_link_libraries(diagnose INTERFACE nowide)
target_include_directories(diagnose INTERFACE ${CMAKE_CURRENT_SOURCE_DIR})

if(PROJECT_IS_TOP_LEVEL)
	add_executable(example example.cpp)
	target_link_libraries(example PUBLIC diagnose)
endif()

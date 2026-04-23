cmake_minimum_required(VERSION 2.8.12...3.29)

project(PipelineInfoExtension)

include_directories(include)

set(EXTENSION_FILES pipeline_info_extension.cpp)

build_static_extension(pipeline_info ${EXTENSION_FILES})
set(PARAMETERS "-warnings")
build_loadable_extension(pipeline_info ${PARAMETERS} ${EXTENSION_FILES})

install(
  TARGETS pipeline_info_extension
  EXPORT "${DUCKDB_EXPORT_SET}"
  LIBRARY DESTINATION "${INSTALL_LIB_DIR}"
  ARCHIVE DESTINATION "${INSTALL_LIB_DIR}")

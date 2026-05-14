import std/[os, osproc, strutils]

const
  buildDir = "build"
  configHeader = buildDir / "include" / "proxsuite" / "config.hpp"
  objectFile = buildDir / "obj" / "proxsuite_c_api.o"
  # TODO: use zig cc to crosscompile it
  staticLib = buildDir / "lib" / "libcproxsuite.a"
  sharedLib = buildDir / "lib" / (DynlibFormat % "cproxsuite")

  # It realy important to use ProxSuite
  proxsuiteConfig = """
#ifndef PROXSUITE_CONFIG_HPP
#define PROXSUITE_CONFIG_HPP
#define PROXSUITE_MAJOR_VERSION 0
#define PROXSUITE_MINOR_VERSION 7
#define PROXSUITE_PATCH_VERSION 3
#define PROXSUITE_VERSION_AT_LEAST(major, minor, patch) \
  ((PROXSUITE_MAJOR_VERSION > (major)) || \
   (PROXSUITE_MAJOR_VERSION == (major) && PROXSUITE_MINOR_VERSION > (minor)) || \
   (PROXSUITE_MAJOR_VERSION == (major) && PROXSUITE_MINOR_VERSION == (minor) && \
    PROXSUITE_PATCH_VERSION >= (patch)))
#endif
"""

proc run(cmd: string) =
  echo cmd
  assert execCmd(cmd) == 0

proc main() =
  createDir buildDir / "include" / "proxsuite"
  createDir buildDir / "obj"
  createDir buildDir / "lib"

  writeFile configHeader, proxsuiteConfig

  run "c++ -std=c++17 -O2 -fPIC " &
    "-Igenerated " &
    "-I" & buildDir / "include" & " " &
    "-Ideps/vendor/proxsuite/include " &
    "-I/usr/include/eigen3 " &
    "-c generated/proxsuite_c_api.cpp " &
    "-o " & objectFile

  run "ar rcs " & staticLib & " " & objectFile

  run "c++ -shared -o " & sharedLib & " " & objectFile

  echo "wrote ", staticLib
  echo "wrote ", sharedLib

when isMainModule:
  main()

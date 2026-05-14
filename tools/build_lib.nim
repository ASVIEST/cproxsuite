import std/[os, osproc, strutils, tempfiles, tables, terminal]
import pkg/zippy/[ziparchives, tarballs]

const
  buildDir = "build"
  configHeader = buildDir / "include" / "proxsuite" / "config.hpp"

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

const crosscompiledDistribution = @[
  "x86_64-linux-gnu",
  "x86_64-windows-gnu",
  "aarch64-linux-gnu",
  "aarch64-windows-gnu"
]

const processOptions = {poStdErrToStdOut, poParentStreams, poEchoCmd}

proc main(
    zigcc = true,
    distributions: seq[string] = crosscompiledDistribution) =

  if not zigcc and distributions.len > 1:
    raiseAssert "Need zigcc to crosscompile"

  let cc =
    if zigcc: "zig c++ "
    else: "c++ "

  let ar =
    if zigcc: "zig ar "
    else: "ar "

  var includeDir = createTempDir("include", "")
  createDir includeDir/"proxsuite"
  writeFile includeDir/"proxsuite"/"config.hpp", proxsuiteConfig

  var compiledObjects = initTable[string, string]()
  var sharedLibs = initTable[string, string]()
  var staticLibs = initTable[string, string]()
  for target in distributions:
    let
      isWin = "windows" in target
      dynlibFormat =
        if isWin: ".dll"
        else: ".so"

    compiledObjects[target] = genTempPath("proxsuite_c_api", ".obj")
    sharedLibs[target] = genTempPath("proxsuite_c_api", ".a")
    staticLibs[target] = genTempPath("proxsuite_c_api", dynlibFormat)

  var cmds: seq[string] = @[]
  for target in distributions:
    cmds.add cc & "-std=c++17 -O2 -fPIC " &
      "-DPROXSUITE_HELPERS_INSTRUCTION_SET_HPP " &
      "-Igenerated " &
      "-I" & includeDir & " " &
      "-Ideps/vendor/proxsuite/include " &
      "-I/usr/include/eigen3 " &
      "-c generated/proxsuite_c_api.cpp " &
      "-o " & compiledObjects[target] & (
      if zigcc: " " & "-target " & target
      else: "")

  assert execProcesses(cmds, processOptions) == 0
  cmds = @[]

  for target in distributions:
    let opath = compiledObjects[target]

    cmds.add ar & "rcs " & staticLibs[target] & " " & opath
    cmds.add cc & "-shared -o " & sharedLibs[target] &
      " " & opath & (
      if zigcc: " " & "-target " & target
      else: "")

  assert execProcesses(cmds, processOptions) == 0

  for target in distributions:
    let
      isWin = "windows" in target
      dynlibFormat =
        if isWin: ".dll"
        else: ".so"
    var zip = initTable[string, string]()
    zip["libcproxsuite.a"] = readFile(staticLibs[target])
    zip["libcproxsuite" & dynlibFormat] = readFile(sharedLibs[target])

    if not dirExists(buildDir):
      createDir(buildDir)

    writeFile(
      buildDir/"libcproxsuite_" & target & ".zip",
      createZipArchive(zip))

when isMainModule:
  let currentDistribution = @[
    # don't sure that it's correct:
    when defined(linux):
      when defined(amd64): "x86_64-linux-gnu"
      elif defined(aarch64): "aarch64-linux-gnu"
      else: raiseAssert "Invalid distribution"
    elif defined(windows):
      when defined(amd64): "x86_64-windows-gnu"
      elif defined(aarch64): "aarch64-windows-gnu"
      else: raiseAssert "Invalid distribution"
    else: raiseAssert "Invalid distribution"
  ]

  let (output, exitCode) = execCmdEx("zig version")
  var zigcc = false
  if exitCode == 0:
    let ver = output.strip().split('.')
    zigcc = parseInt(ver[0]) > 0 or parseInt(ver[1]) > 6

  if not zigcc:
    stdout.styledWriteLine(
      fgYellow,
      "NOTE: you don't have zigcc installed so compiling only current distribution")

  main(
    zigcc,
    if zigcc: crosscompiledDistribution
    else: currentDistribution)

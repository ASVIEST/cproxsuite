task generate, "Generate bindings":
  when not defined(feature.cproxsuite.gen):
    # atlas install --feature=gen
    raiseAssert "To run bindings generation, install cproxsuite with gen feature"

  exec "nim c -d:release -r tools/nanobind_cgen.nim " &
    "--project-root deps/vendor/proxsuite " &
    "--bindings-dir deps/vendor/proxsuite/bindings/python " &
    "--input deps/vendor/proxsuite/bindings/python/src/expose-all.cpp " &
    "--input deps/vendor/proxsuite/bindings/python/helpers/instruction-set.cpp"

task buildLib, "Build library":
  when not defined(feature.cproxsuite.genlib):
    # atlas install --feature=genlib
    raiseAssert "To run lib build, install cproxsuite with genlib feature"

  exec "nim c -r tools/build_lib.nim"

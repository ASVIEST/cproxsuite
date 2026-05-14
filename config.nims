task generate, "Generate bindings":
  when not defined(feature.cproxsuite.gen):
    # atlas install --feature=gen
    raiseAssert "To run bindings generation, install it with gen feature"

  exec "nim c -d:release -r tools/nanobind_cgen.nim " &
    "--project-root deps/vendor/proxsuite " &
    "--bindings-dir deps/vendor/proxsuite/bindings/python " &
    "--input deps/vendor/proxsuite/bindings/python/src/expose-all.cpp " &
    "--input deps/vendor/proxsuite/bindings/python/helpers/instruction-set.cpp"

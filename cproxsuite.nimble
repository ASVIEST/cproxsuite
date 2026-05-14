feature "genlib":
  requires "zippy"

after install:
  block clonning:
    when defined(feature.cproxsuite.genlib):
      # for genlib we need compile proxsuite.
      if dirExists("deps/vendor/proxsuite"):
        break clonning
      exec "git clone --depth 1 "&
        "https://github.com/Simple-Robotics/proxsuite deps/vendor/proxsuite"
      break clonning
    when defined(feature.cproxsuite.gen):
      # can be sparse: TODO implement
      if dirExists("deps/vendor/proxsuite"):
        break clonning
      exec "git clone --depth 1 "&
        "https://github.com/Simple-Robotics/proxsuite deps/vendor/proxsuite"

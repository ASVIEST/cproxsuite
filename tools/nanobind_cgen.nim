import std/[algorithm, json, os, osproc, sequtils, sets, strutils, tables]

type
  Config = object
    projectRoot: string
    bindingsDir: string
    clangExe: string
    cppStd: string
    moduleName: string
    cPrefix: string
    outHeader: string
    outImpl: string
    astJson: string
    astFilters: seq[string]
    inputs: seq[string]
    clangArgs: seq[string]
    implIncludes: seq[string]
    defaultImplIncludes: bool
    pythonIncludes: bool
    astStubs: bool
    verbose: bool

  BindingKind = enum
    bkClass, bkEnum

  ConstructorBinding = object
    args: seq[string]
    argNames: seq[string]
    doc: string
    loc: string

  FieldBinding = object
    pyName: string
    cppName: string
    cppType: string
    readonly: bool
    doc: string
    loc: string

  MethodBinding = object
    pyName: string
    cppName: string
    returnType: string
    params: seq[string]
    argNames: seq[string]
    constMethod: bool
    doc: string
    loc: string

  EnumValueBinding = object
    pyName: string
    cppName: string
    doc: string
    loc: string

  ClassBinding = ref object
    pyName: string
    cppType: string
    cName: string
    doc: string
    loc: string
    constructors: seq[ConstructorBinding]
    fields: seq[FieldBinding]
    methods: seq[MethodBinding]

  EnumBinding = ref object
    pyName: string
    cppType: string
    cName: string
    doc: string
    loc: string
    values: seq[EnumValueBinding]

  ModuleFunctionBinding = object
    pyName: string
    cppName: string
    returnType: string
    params: seq[string]
    argNames: seq[string]
    doc: string
    loc: string

  Model = object
    classes: Table[string, ClassBinding]
    enums: Table[string, EnumBinding]
    moduleFunctions: seq[ModuleFunctionBinding]
    skipped: seq[string]

  GenContext = object
    cfg: Config
    model: Model
    header: seq[string]
    impl: seq[string]
    bodyProtos: seq[string]
    implBody: seq[string]
    skipped: seq[string]
    usedHelpers: HashSet[string]
    docNameMap: Table[string, seq[string]]
    docNameRelatedAccessors: HashSet[string]
    generated: int

  FuncSig = object
    ok: bool
    ret: string
    params: seq[string]
    argNames: seq[string]
    isConst: bool

  TypeMap = object
    ok: bool
    cType: string
    cppType: string
    isVoid: bool
    isClass: bool
    className: string
    byRef: bool
    isConst: bool
    isEnum: bool
    isString: bool
    isOptional: bool
    castHelper: string
    needsLocal: bool

  FieldViewKind = enum
    fvkNone, fvkDenseVectorDouble, fvkDenseMatrixDouble,
    fvkSparseMatrixDoubleInt, fvkSparseMatrixBoolInt

  FieldViewMap = object
    ok: bool
    cType: string
    kind: FieldViewKind

proc usage() =
  echo """
nanobind_cgen - generate a small C API from nanobind bindings via clang AST.

Usage:
  nim c -r tools/nanobind_cgen.nim -- [options] [-- extra clang++ args...]

Options:
  -i, --input:FILE             C++ binding translation unit. Repeatable.
                               Defaults to proxsuite/bindings/python/src/expose-all.cpp
                               and helpers/instruction-set.cpp when present.
      --ast-json:FILE          Read a precomputed clang JSON AST instead of
                               invoking clang++. Use '-' for stdin.
      --ast-filter:PATTERN     clang AST dump filter. Repeatable.
                               Defaults to expose and nb_module.
      --no-ast-filter          Dump the whole AST. This can be very large.
      --project-root:DIR       Default: proxsuite
      --bindings-dir:DIR       Default: proxsuite/bindings/python
      --clang:PATH             Default: clang++
      --std:STD                Default: c++17
      --module-name:NAME       PYTHON_MODULE_NAME macro. Default: proxsuite_pywrap
      --prefix:IDENT           C identifier prefix. Default: proxsuite_c
      --out-header:FILE        Default: generated/proxsuite_c_api.h
      --out-impl:FILE          Default: generated/proxsuite_c_api.cpp
      --impl-include:HEADER    Extra #include for generated C++ file. Repeatable.
      --no-default-includes    Do not emit the default proxsuite C++ includes.
      --no-python-includes     Do not add python3-config --includes to clang++.
      --no-ast-stubs           Do not add lightweight AST-only stubs for
                               nanobind, proxsuite/config.hpp and cereal.
  -v, --verbose                Print clang++ commands.
  -h, --help                   Show this help.

The clang invocation uses -Xclang -ast-dump=json -fsyntax-only. Extra clang++
arguments after '--' are appended after the built-in include paths and defines.
"""

proc defaultConfig(): Config =
  result.projectRoot = "proxsuite"
  result.bindingsDir = "proxsuite/bindings/python"
  result.clangExe = "clang++"
  result.cppStd = "c++17"
  result.moduleName = "proxsuite_pywrap"
  result.cPrefix = "proxsuite_c"
  result.outHeader = "generated/proxsuite_c_api.h"
  result.outImpl = "generated/proxsuite_c_api.cpp"
  result.astFilters = @["expose", "nb_module"]
  result.defaultImplIncludes = true
  result.pythonIncludes = true
  result.astStubs = true

proc splitArgsAtDoubleDash(args: seq[string]): tuple[ours, clang: seq[string]] =
  var afterDash = false
  for arg in args:
    if afterDash:
      result.clang.add arg
    elif arg == "--":
      afterDash = true
    else:
      result.ours.add arg

proc parseConfig(): Config =
  result = defaultConfig()
  let split = splitArgsAtDoubleDash(commandLineParams())
  result.clangArgs = split.clang

  var i = 0

  proc takeValue(key: string; current: var int; val: string): string =
    if val.len > 0:
      return val
    inc current
    if current >= split.ours.len:
      quit "missing value for option: " & key, 2
    split.ours[current]

  while i < split.ours.len:
    let arg = split.ours[i]
    if arg == "-h" or arg == "--help":
      usage()
      quit 0
    elif arg == "-v" or arg == "--verbose":
      result.verbose = true
    elif arg == "--no-default-includes":
      result.defaultImplIncludes = false
    elif arg == "--no-python-includes":
      result.pythonIncludes = false
    elif arg == "--no-ast-stubs":
      result.astStubs = false
    elif arg.startsWith("-i") and not arg.startsWith("--"):
      var val = ""
      if arg.len > 2:
        val = arg[2 .. ^1]
        if val.startsWith(":") or val.startsWith("="):
          val = val[1 .. ^1]
      result.inputs.add takeValue("-i", i, val)
    elif arg.startsWith("--"):
      var keyVal = arg[2 .. ^1]
      var key = keyVal
      var val = ""
      for sep in ["=", ":"]:
        let p = keyVal.find(sep)
        if p >= 0:
          key = keyVal[0 ..< p]
          val = keyVal[p + 1 .. ^1]
          break
      case key
      of "input":
        result.inputs.add takeValue("--input", i, val)
      of "ast-json":
        result.astJson = takeValue("--ast-json", i, val)
      of "ast-filter":
        if result.astFilters == @["expose", "nb_module"]:
          result.astFilters = @[]
        result.astFilters.add takeValue("--ast-filter", i, val)
      of "no-ast-filter":
        result.astFilters = @[]
      of "project-root":
        result.projectRoot = takeValue("--project-root", i, val)
      of "bindings-dir":
        result.bindingsDir = takeValue("--bindings-dir", i, val)
      of "clang":
        result.clangExe = takeValue("--clang", i, val)
      of "std":
        result.cppStd = takeValue("--std", i, val)
      of "module-name":
        result.moduleName = takeValue("--module-name", i, val)
      of "prefix":
        result.cPrefix = takeValue("--prefix", i, val)
      of "out-header":
        result.outHeader = takeValue("--out-header", i, val)
      of "out-impl":
        result.outImpl = takeValue("--out-impl", i, val)
      of "impl-include":
        result.implIncludes.add takeValue("--impl-include", i, val)
      else:
        quit "unknown option: " & key, 2
    else:
      result.inputs.add arg
    inc i

  if result.inputs.len == 0 and result.astJson.len == 0:
    let exposeAll = result.bindingsDir / "src" / "expose-all.cpp"
    let instructionSet = result.bindingsDir / "helpers" / "instruction-set.cpp"
    if fileExists(exposeAll):
      result.inputs.add exposeAll
    if fileExists(instructionSet):
      result.inputs.add instructionSet

proc hasField(n: JsonNode; key: string): bool =
  n != nil and n.kind == JObject and n.hasKey(key)

proc jstr(n: JsonNode; key: string; default = ""): string =
  if n.hasField(key) and n[key].kind == JString:
    n[key].getStr
  else:
    default

proc childNodes(n: JsonNode): seq[JsonNode] =
  if n.hasField("inner") and n["inner"].kind == JArray:
    for child in n["inner"].items:
      result.add child

proc qualType(n: JsonNode): string =
  if n.hasField("type") and n["type"].hasField("qualType"):
    result = n["type"]["qualType"].getStr

proc decodeStringLiteral(s: string): string =
  if s.len >= 2 and s[0] == '"':
    try:
      return parseJson(s).getStr
    except JsonParsingError:
      discard
  s.strip(chars = {'"'})

proc firstStringLiteral(n: JsonNode): string =
  if n == nil:
    return
  if jstr(n, "kind") == "StringLiteral" and n.hasField("value"):
    return decodeStringLiteral(n["value"].getStr)
  for child in childNodes(n):
    result = firstStringLiteral(child)
    if result.len > 0:
      return

proc stringLiterals(n: JsonNode): seq[string] =
  if n == nil:
    return
  if jstr(n, "kind") == "StringLiteral" and n.hasField("value"):
    result.add decodeStringLiteral(n["value"].getStr)
  for child in childNodes(n):
    result.add stringLiterals(child)

proc containsNanobindArg(n: JsonNode): bool =
  if n == nil:
    return
  if "nanobind::arg" in qualType(n):
    return true
  for child in childNodes(n):
    if containsNanobindArg(child):
      return true

proc nanobindArgNames(args: openArray[JsonNode]; start: int): seq[string] =
  if start >= args.len:
    return
  for i in start ..< args.len:
    if containsNanobindArg(args[i]):
      let name = firstStringLiteral(args[i])
      if name.len > 0:
        result.add name

proc docStringFromArgs(args: openArray[JsonNode]; start: int): string =
  if start >= args.len:
    return
  for i in start ..< args.len:
    if containsNanobindArg(args[i]):
      continue
    let parts = stringLiterals(args[i])
    if parts.len > 0:
      return parts.join("")

proc bindingDocString(n: JsonNode): string =
  let parts = stringLiterals(n)
  if parts.len >= 2:
    result = parts[1]

proc directDeclParamNames(decl: JsonNode): seq[string] =
  if decl == nil:
    return
  for child in childNodes(decl):
    if jstr(child, "kind") == "ParmVarDecl":
      result.add jstr(child, "name")

proc mergedArgNames(primary, fallback: seq[string]; count: int): seq[string] =
  for i in 0 ..< count:
    if i < primary.len and primary[i].len > 0:
      result.add primary[i]
    elif i < fallback.len and fallback[i].len > 0:
      result.add fallback[i]
    else:
      result.add ""

proc locString(n: JsonNode): string =
  if n == nil:
    return
  if n.hasField("loc"):
    let loc = n["loc"]
    if loc.hasField("file") and loc.hasField("line"):
      return loc["file"].getStr & ":" & $loc["line"].getInt
  if n.hasField("range") and n["range"].hasField("begin"):
    let loc = n["range"]["begin"]
    if loc.hasField("file") and loc.hasField("line"):
      return loc["file"].getStr & ":" & $loc["line"].getInt
  for child in childNodes(n):
    result = locString(child)
    if result.len > 0:
      return

proc splitTopLevel(s: string; sep = ','): seq[string] =
  var start = 0
  var angleDepth = 0
  var parenDepth = 0
  var bracketDepth = 0
  for i, ch in s:
    case ch
    of '<': inc angleDepth
    of '>':
      if angleDepth > 0: dec angleDepth
    of '(':
      inc parenDepth
    of ')':
      if parenDepth > 0: dec parenDepth
    of '[':
      inc bracketDepth
    of ']':
      if bracketDepth > 0: dec bracketDepth
    else:
      discard
    if ch == sep and angleDepth == 0 and parenDepth == 0 and bracketDepth == 0:
      result.add s[start ..< i].strip
      start = i + 1
  let tail = s[start .. ^1].strip
  if tail.len > 0:
    result.add tail

proc topLevelPrefix(s: string; stop: char): string =
  var angleDepth = 0
  var parenDepth = 0
  var bracketDepth = 0
  var inString = false
  var escaped = false
  for i, ch in s:
    if inString:
      if escaped:
        escaped = false
      elif ch == '\\':
        escaped = true
      elif ch == '"':
        inString = false
      continue
    case ch
    of '"':
      inString = true
    of '<': inc angleDepth
    of '>':
      if angleDepth > 0: dec angleDepth
    of '(':
      inc parenDepth
    of ')':
      if parenDepth > 0: dec parenDepth
    of '[':
      inc bracketDepth
    of ']':
      if bracketDepth > 0: dec bracketDepth
    else:
      discard
    if ch == stop and angleDepth == 0 and parenDepth == 0 and bracketDepth == 0:
      return s[0 ..< i].strip
  s.strip

proc firstParenBody(s: string): string =
  let openPos = s.find('(')
  if openPos < 0:
    return
  var depth = 1
  var inString = false
  var escaped = false
  var i = openPos + 1
  while i < s.len:
    let ch = s[i]
    if inString:
      if escaped:
        escaped = false
      elif ch == '\\':
        escaped = true
      elif ch == '"':
        inString = false
      inc i
      continue
    case ch
    of '"':
      inString = true
    of '(':
      inc depth
    of ')':
      dec depth
      if depth == 0:
        return s[openPos + 1 ..< i].strip
    else:
      discard
    inc i

proc sourceParamName(param: string): string =
  let p = topLevelPrefix(param, '=').strip
  if p.len == 0 or p == "void":
    return
  var finish = p.len - 1
  while finish >= 0 and p[finish].isSpaceAscii:
    dec finish
  if finish < 0:
    return
  var start = finish
  while start >= 0 and (p[start].isAlphaNumeric or p[start] == '_'):
    dec start
  if start == finish:
    return
  result = p[start + 1 .. finish]

proc sourceParamNames(decl: JsonNode): seq[string] =
  if decl == nil:
    return
  var file = ""
  var line = 0
  if decl.hasField("loc"):
    let loc = decl["loc"]
    if loc.hasField("file") and loc.hasField("line"):
      file = loc["file"].getStr
      line = loc["line"].getInt
  if (file.len == 0 or line <= 0) and decl.hasField("range") and
     decl["range"].hasField("begin"):
    let loc = decl["range"]["begin"]
    if loc.hasField("file") and loc.hasField("line"):
      file = loc["file"].getStr
      line = loc["line"].getInt
  if file.len == 0 or line <= 0 or not fileExists(file):
    return
  let lines = readFile(file).splitLines
  if line > lines.len:
    return
  var text = ""
  let last = min(lines.len - 1, line + 80)
  for i in (line - 1) .. last:
    text.add lines[i]
    text.add "\n"
    let body = firstParenBody(text)
    if body.len > 0:
      for param in splitTopLevel(body):
        result.add sourceParamName(param)
      return

proc allEmpty(names: seq[string]): bool =
  if names.len == 0:
    return true
  for name in names:
    if name.len > 0:
      return false
  true

proc declParamNames(decl: JsonNode): seq[string] =
  result = directDeclParamNames(decl)
  if allEmpty(result):
    result = sourceParamNames(decl)

proc conventionalParamNames(name: string; count: int): seq[string] =
  case name
  of "solve":
    if count == 3:
      return @["x", "y", "z"]
  of "init_qp_in_place":
    if count == 3:
      return @["dim", "n_eq", "n_in"]
  of "insert":
    if count == 1:
      return @["qp"]
  of "get":
    if count == 1:
      return @["i"]
  of "is_valid":
    if count == 1:
      return @["box_constraints"]
  else:
    discard

proc templateArgsAfter(s, marker: string): seq[string] =
  let pos = s.find(marker)
  if pos < 0:
    return
  let start = pos + marker.len
  var depth = 1
  var i = start
  while i < s.len:
    case s[i]
    of '<': inc depth
    of '>':
      dec depth
      if depth == 0:
        let inside = s[start ..< i].strip
        if inside.len == 0:
          return @[]
        return splitTopLevel(inside)
    else:
      discard
    inc i

proc extractNanobindBindingType(q: string): tuple[ok: bool; kind: BindingKind; cppType: string] =
  for marker in ["nanobind::class_<", "::nanobind::class_<"]:
    let args = templateArgsAfter(q, marker)
    if args.len > 0:
      return (true, bkClass, args[0])
  for marker in ["nanobind::enum_<", "::nanobind::enum_<"]:
    let args = templateArgsAfter(q, marker)
    if args.len > 0:
      return (true, bkEnum, args[0])

proc looksGeneric(cppType: string): bool =
  let t = cppType.strip
  if t.len == 0:
    return true
  for bad in ["type-parameter", "<T", ", T", " T>", "<I", ", I", " I>",
              "auto "]:
    if bad in t:
      return true

proc cIdent(s: string): string =
  var prevUnderscore = false
  var prevUpper = false
  for i, ch in s:
    if ch.isAlphaNumeric or ch == '_':
      if ch == '_':
        if result.len > 0 and not prevUnderscore:
          result.add '_'
          prevUnderscore = true
        prevUpper = false
      else:
        let nextIsLower =
          i + 1 < s.len and s[i + 1].isLowerAscii
        if ch.isUpperAscii and result.len > 0 and not prevUnderscore and
           (not prevUpper or nextIsLower):
          result.add '_'
        result.add ch.toLowerAscii
        prevUnderscore = false
        prevUpper = ch.isUpperAscii
    else:
      if result.len > 0 and not prevUnderscore:
        result.add '_'
        prevUnderscore = true
      prevUpper = false
  result = result.strip(chars = {'_'})
  if result.len == 0:
    result = "unnamed"
  if result[0].isDigit:
    result = "_" & result

proc shortCppForCName(cppType: string): string =
  result = cppType
  for prefix in ["proxsuite::", "std::", "Eigen::"]:
    result = result.replace(prefix, "")
  result = result.replace("linalg::veg::", "")
  result = result.replace(" ", "")
  result = result.replace("const", "")

proc makeCName(prefix, cppType: string): string =
  prefix & "_" & cIdent(shortCppForCName(cppType))

proc findBindingObject(n: JsonNode): tuple[ok: bool; kind: BindingKind; cppType, pyName: string] =
  if n == nil:
    return
  let bindingType = extractNanobindBindingType(qualType(n))
  if bindingType.ok:
    let pyName = firstStringLiteral(n)
    if pyName.len > 0:
      return (true, bindingType.kind, bindingType.cppType, pyName)
  for child in childNodes(n):
    result = findBindingObject(child)
    if result.ok:
      return

proc callName(n: JsonNode): string =
  let kids = childNodes(n)
  if kids.len == 0:
    return
  result = jstr(kids[0], "name", jstr(kids[0], "member"))

proc callBase(n: JsonNode): JsonNode =
  let kids = childNodes(n)
  if kids.len == 0:
    return nil
  let member = kids[0]
  let memberKids = childNodes(member)
  if memberKids.len > 0:
    return memberKids[0]

proc callArgs(n: JsonNode): seq[JsonNode] =
  let kids = childNodes(n)
  if kids.len > 1:
    result = kids[1 .. ^1]

proc findReferencedDecl(n: JsonNode; wantedKinds: openArray[string]): JsonNode =
  if n == nil:
    return
  if n.hasField("referencedDecl"):
    let decl = n["referencedDecl"]
    if jstr(decl, "kind") in wantedKinds:
      return decl
  for child in childNodes(n):
    result = findReferencedDecl(child, wantedKinds)
    if result != nil:
      return

proc findInitTypes(n: JsonNode): tuple[ok: bool; args: seq[string]] =
  if n == nil:
    return
  let q = qualType(n)
  for marker in ["nanobind::init<", "::nanobind::init<"]:
    if marker in q:
      return (true, templateArgsAfter(q, marker))
  for child in childNodes(n):
    result = findInitTypes(child)
    if result.ok:
      return

proc cleanupType(t: string): string =
  result = t.strip
  result = result.replace("class ", "")
  result = result.replace("struct ", "")
  result = result.replace("enum ", "")
  result = result.replace("volatile ", "")
  while result.startsWith("const "):
    result = result[6 .. ^1].strip
  if result.endsWith(" const"):
    result = result[0 ..< result.len - 6].strip

proc stripCvRef(t: string): tuple[base: string; byRef, isConst: bool] =
  var s = t.strip
  result.isConst = s.startsWith("const ") or s.endsWith(" const") or
                   s.contains(" const ")
  if s.endsWith("&"):
    result.byRef = true
    s = s[0 ..< s.len - 1].strip
  if s.endsWith("&&"):
    result.byRef = true
    s = s[0 ..< s.len - 2].strip
  result.base = cleanupType(s)

proc parseFunctionType(t: string): FuncSig =
  let s0 = t.strip
  if s0.len == 0:
    return
  var depthAngle = 0
  var openPos = -1
  for i, ch in s0:
    case ch
    of '<': inc depthAngle
    of '>':
      if depthAngle > 0: dec depthAngle
    of '(':
      if depthAngle == 0:
        openPos = i
        break
    else:
      discard
  if openPos < 0:
    return

  var depth = 1
  var closePos = -1
  var i = openPos + 1
  while i < s0.len:
    case s0[i]
    of '(':
      inc depth
    of ')':
      dec depth
      if depth == 0:
        closePos = i
        break
    else:
      discard
    inc i
  if closePos < 0:
    return

  result.ok = true
  result.ret = cleanupType(s0[0 ..< openPos])
  let inside = s0[openPos + 1 ..< closePos].strip
  if inside.len > 0 and inside != "void":
    result.params = splitTopLevel(inside)
  let suffix = s0[closePos + 1 .. ^1]
  result.isConst = " const" in suffix

proc addClass(model: var Model; pyName, cppType, loc: string;
              doc = ""): ClassBinding =
  if looksGeneric(cppType):
    return nil
  let key = cppType & "|" & pyName
  if not model.classes.hasKey(key):
    model.classes[key] = ClassBinding(pyName: pyName, cppType: cppType,
                                      doc: doc, loc: loc)
  elif model.classes[key].doc.len == 0 and doc.len > 0:
    model.classes[key].doc = doc
  model.classes[key]

proc addEnum(model: var Model; pyName, cppType, loc: string;
             doc = ""): EnumBinding =
  if looksGeneric(cppType):
    return nil
  let key = cppType & "|" & pyName
  if not model.enums.hasKey(key):
    model.enums[key] = EnumBinding(pyName: pyName, cppType: cppType,
                                   doc: doc, loc: loc)
  elif model.enums[key].doc.len == 0 and doc.len > 0:
    model.enums[key].doc = doc
  model.enums[key]

proc addConstructor(cls: ClassBinding; ctor: ConstructorBinding) =
  for i in 0 ..< cls.constructors.len:
    if cls.constructors[i].args == ctor.args:
      if cls.constructors[i].argNames.len == 0 and ctor.argNames.len > 0:
        cls.constructors[i].argNames = ctor.argNames
      if cls.constructors[i].doc.len == 0 and ctor.doc.len > 0:
        cls.constructors[i].doc = ctor.doc
      return
  cls.constructors.add ctor

proc addField(cls: ClassBinding; field: FieldBinding) =
  for i in 0 ..< cls.fields.len:
    if cls.fields[i].pyName == field.pyName and
       cls.fields[i].cppName == field.cppName:
      if cls.fields[i].doc.len == 0 and field.doc.len > 0:
        cls.fields[i].doc = field.doc
      return
  cls.fields.add field

proc addMethod(cls: ClassBinding; meth: MethodBinding) =
  for i in 0 ..< cls.methods.len:
    if cls.methods[i].pyName == meth.pyName and cls.methods[i].cppName == meth.cppName and
       cls.methods[i].params == meth.params and cls.methods[i].returnType == meth.returnType:
      if cls.methods[i].argNames.len == 0 and meth.argNames.len > 0:
        cls.methods[i].argNames = meth.argNames
      if cls.methods[i].doc.len == 0 and meth.doc.len > 0:
        cls.methods[i].doc = meth.doc
      return
  cls.methods.add meth

proc addEnumValue(en: EnumBinding; value: EnumValueBinding) =
  for i in 0 ..< en.values.len:
    if en.values[i].pyName == value.pyName:
      if en.values[i].doc.len == 0 and value.doc.len > 0:
        en.values[i].doc = value.doc
      return
  en.values.add value

proc collectBindingConstruct(n: JsonNode; model: var Model) =
  let kind = jstr(n, "kind")
  if kind notin ["CXXTemporaryObjectExpr", "CXXFunctionalCastExpr", "CXXConstructExpr"]:
    return
  let binding = extractNanobindBindingType(qualType(n))
  if not binding.ok:
    return
  let pyName = firstStringLiteral(n)
  if pyName.len == 0:
    return
  if binding.kind == bkClass:
    discard model.addClass(pyName, binding.cppType, locString(n),
                           bindingDocString(n))
  else:
    discard model.addEnum(pyName, binding.cppType, locString(n),
                          bindingDocString(n))

proc collectClassCall(n: JsonNode; cls: ClassBinding; name: string; model: var Model) =
  let args = callArgs(n)
  if name in ["def_rw", "def_ro"]:
    if args.len < 2:
      return
    let pyName = firstStringLiteral(args[0])
    if pyName.len == 0:
      return
    let decl = findReferencedDecl(args[1], ["FieldDecl"])
    if decl == nil:
      model.skipped.add cls.cppType & "." & pyName & " at " & locString(n) &
                        ": field pointer was not resolved by clang AST"
      return
    addField cls, FieldBinding(
      pyName: pyName,
      cppName: jstr(decl, "name"),
      cppType: if decl.hasField("type"): decl["type"]["qualType"].getStr else: "",
      readonly: name == "def_ro",
      doc: docStringFromArgs(args, 2),
      loc: locString(n))
    return

  if name != "def" or args.len == 0:
    return

  let init = findInitTypes(args[0])
  if init.ok:
    addConstructor cls, ConstructorBinding(
      args: init.args,
      argNames: mergedArgNames(nanobindArgNames(args, 1), @[], init.args.len),
      doc: docStringFromArgs(args, 1),
      loc: locString(n))
    return

  let pyName = firstStringLiteral(args[0])
  if pyName.len == 0 or pyName.startsWith("__"):
    return
  if args.len < 2:
    return
  let decl = findReferencedDecl(args[1], ["CXXMethodDecl"])
  if decl == nil:
    model.skipped.add cls.cppType & "." & pyName & " at " & locString(n) &
                      ": method pointer was not resolved by clang AST"
    return
  let sig = parseFunctionType(if decl.hasField("type"): decl["type"]["qualType"].getStr else: "")
  if not sig.ok:
    model.skipped.add cls.cppType & "." & pyName & " at " & locString(n) &
                      ": cannot parse method type"
    return
  var fallbackNames = declParamNames(decl)
  if allEmpty(fallbackNames):
    fallbackNames = conventionalParamNames(jstr(decl, "name"), sig.params.len)
  addMethod cls, MethodBinding(
    pyName: pyName,
    cppName: jstr(decl, "name"),
    returnType: sig.ret,
    params: sig.params,
    argNames: mergedArgNames(nanobindArgNames(args, 2),
                             fallbackNames,
                             sig.params.len),
    constMethod: sig.isConst,
    doc: docStringFromArgs(args, 2),
    loc: locString(n))

proc collectEnumCall(n: JsonNode; en: EnumBinding; name: string) =
  if name != "value":
    return
  let args = callArgs(n)
  if args.len < 2:
    return
  let pyName = firstStringLiteral(args[0])
  if pyName.len == 0:
    return
  let decl = findReferencedDecl(args[1], ["EnumConstantDecl"])
  addEnumValue en, EnumValueBinding(
    pyName: pyName,
    cppName: if decl == nil: pyName else: jstr(decl, "name", pyName),
    doc: docStringFromArgs(args, 2),
    loc: locString(n))

proc collectModuleCall(n: JsonNode; name: string; model: var Model) =
  if name != "def":
    return
  let base = callBase(n)
  if base == nil or "nanobind::module_" notin qualType(base):
    return
  let args = callArgs(n)
  if args.len < 2:
    return
  let pyName = firstStringLiteral(args[0])
  if pyName.len == 0:
    return
  let decl = findReferencedDecl(args[1], ["FunctionDecl"])
  if decl == nil:
    return
  let sig = parseFunctionType(if decl.hasField("type"): decl["type"]["qualType"].getStr else: "")
  if sig.ok:
    model.moduleFunctions.add ModuleFunctionBinding(
      pyName: pyName,
      cppName: jstr(decl, "name"),
      returnType: sig.ret,
      params: sig.params,
      argNames: mergedArgNames(nanobindArgNames(args, 2),
                               declParamNames(decl),
                               sig.params.len),
      doc: docStringFromArgs(args, 2),
      loc: locString(n))

proc walkAst(n: JsonNode; model: var Model) =
  if n == nil:
    return
  collectBindingConstruct(n, model)

  for child in childNodes(n):
    walkAst(child, model)

  if jstr(n, "kind") == "CXXMemberCallExpr":
    let name = callName(n)
    let binding = findBindingObject(callBase(n))
    if binding.ok:
      case binding.kind
      of bkClass:
        let cls = model.addClass(binding.pyName, binding.cppType, locString(n))
        if cls != nil:
          collectClassCall(n, cls, name, model)
      of bkEnum:
        let en = model.addEnum(binding.pyName, binding.cppType, locString(n))
        if en != nil:
          collectEnumCall(n, en, name)
    else:
      collectModuleCall(n, name, model)

proc readPythonConfigIncludes(): seq[string] =
  let res = execCmdEx("python3-config --includes",
                      options = {poUsePath, poStdErrToStdOut})
  if res.exitCode == 0:
    for part in res.output.splitWhitespace:
      if part.len > 0:
        result.add part

proc parseJsonObjects(text: string): seq[JsonNode] =
  var start = -1
  var depth = 0
  var inString = false
  var escaped = false

  for i, ch in text:
    if start < 0:
      if ch == '{':
        start = i
        depth = 1
      continue

    if inString:
      if escaped:
        escaped = false
      elif ch == '\\':
        escaped = true
      elif ch == '"':
        inString = false
      continue

    case ch
    of '"':
      inString = true
    of '{':
      inc depth
    of '}':
      dec depth
      if depth == 0:
        result.add parseJson(text[start .. i])
        start = -1
    else:
      discard

proc readNanobindInclude(): string =
  let res = execCmdEx("python3 -m nanobind --include_dir",
                      options = {poUsePath, poStdErrToStdOut})
  if res.exitCode == 0:
    result = res.output.strip

proc packageVersion(projectRoot: string): tuple[major, minor, patch: string] =
  result = ("0", "0", "0")
  let pkg = projectRoot / "package.xml"
  if not fileExists(pkg):
    return
  let text = readFile(pkg)
  let openTag = text.find("<version>")
  let closeTag = text.find("</version>")
  if openTag < 0 or closeTag <= openTag:
    return
  let parts = text[openTag + "<version>".len ..< closeTag].strip.split(".")
  if parts.len > 0: result.major = parts[0]
  if parts.len > 1: result.minor = parts[1]
  if parts.len > 2: result.patch = parts[2]

proc writeAstStub(path, content: string) =
  createDir path.parentDir
  if not fileExists(path) or readFile(path) != content:
    writeFile(path, content)

proc ensureAstStubs(cfg: Config): string =
  if not cfg.astStubs:
    return
  result = getTempDir() / "nanobind_cgen_ast_stubs"
  let version = packageVersion(cfg.projectRoot)
  writeAstStub(result / "proxsuite" / "config.hpp",
               "#ifndef PROXSUITE_CONFIG_HPP\n" &
               "#define PROXSUITE_CONFIG_HPP\n" &
               "#define PROXSUITE_MAJOR_VERSION " & version.major & "\n" &
               "#define PROXSUITE_MINOR_VERSION " & version.minor & "\n" &
               "#define PROXSUITE_PATCH_VERSION " & version.patch & "\n" &
               "#define PROXSUITE_VERSION_AT_LEAST(major, minor, patch) \\\n" &
               "  ((PROXSUITE_MAJOR_VERSION > (major)) || \\\n" &
               "   (PROXSUITE_MAJOR_VERSION == (major) && PROXSUITE_MINOR_VERSION > (minor)) || \\\n" &
               "   (PROXSUITE_MAJOR_VERSION == (major) && PROXSUITE_MINOR_VERSION == (minor) && \\\n" &
               "    PROXSUITE_PATCH_VERSION >= (patch)))\n" &
               "#endif\n")
  writeAstStub(result / "cereal" / "cereal.hpp",
               """
#ifndef CEREAL_CEREAL_HPP_
#define CEREAL_CEREAL_HPP_
#include <utility>
#define CEREAL_NVP(value) value
namespace cereal {
template<typename T>
T& make_nvp(const char*, T& value) { return value; }
template<typename T>
const T& make_nvp(const char*, const T& value) { return value; }
}
#endif
""")
  let archiveStub = """
#ifndef CEREAL_ARCHIVE_STUB_HPP_
#define CEREAL_ARCHIVE_STUB_HPP_
namespace cereal {
struct BinaryInputArchive {
  template<typename Stream> explicit BinaryInputArchive(Stream&) {}
  template<typename... Args> void operator()(Args&&...) {}
};
struct BinaryOutputArchive {
  template<typename Stream> explicit BinaryOutputArchive(Stream&) {}
  template<typename... Args> void operator()(Args&&...) {}
};
struct JSONInputArchive {
  template<typename Stream> explicit JSONInputArchive(Stream&) {}
  template<typename... Args> void operator()(Args&&...) {}
};
struct JSONOutputArchive {
  template<typename Stream> explicit JSONOutputArchive(Stream&) {}
  template<typename... Args> void operator()(Args&&...) {}
};
struct XMLInputArchive {
  template<typename Stream> explicit XMLInputArchive(Stream&) {}
  template<typename... Args> void operator()(Args&&...) {}
};
struct XMLOutputArchive {
  template<typename Stream> explicit XMLOutputArchive(Stream&) {}
  template<typename... Args> void operator()(Args&&...) {}
};
}
#endif
"""
  writeAstStub(result / "cereal" / "archives" / "binary.hpp", archiveStub)
  writeAstStub(result / "cereal" / "archives" / "json.hpp", archiveStub)
  writeAstStub(result / "cereal" / "archives" / "xml.hpp", archiveStub)
  let nanobindStub = """
#ifndef NANOBIND_NANOBIND_H_
#define NANOBIND_NANOBIND_H_
#include <cstdint>
#include <optional>
#include <string>
#include <type_traits>
#include <utility>

#define NB_NAMESPACE nanobind
#define NAMESPACE_BEGIN(name) namespace name {
#define NAMESPACE_END(name) }
#define NB_CONCAT_2(a, b) a##b
#define NB_CONCAT(a, b) NB_CONCAT_2(a, b)
#define NB_MODULE(name, variable) \
  void NB_CONCAT(nb_module_, name)(::nanobind::module_ variable)
#define NB_TYPE_CASTER(Type, Name) Type value;

namespace nanobind {
enum class rv_policy { reference };

struct cleanup_list {};

struct handle {
  bool is_none() const { return false; }
  handle release() const { return {}; }
};

inline handle none() { return {}; }

struct bytes {
  const char* c_str() const { return ""; }
};

struct arg {
  explicit arg(const char*) {}
  arg none() const { return *this; }
  template<typename T>
  arg operator=(T&&) const { return *this; }
};

struct attr_proxy {
  template<typename T>
  attr_proxy& operator=(T&&) { return *this; }
};

struct module_ {
  std::string doc_storage;
  std::string& doc() { return doc_storage; }
  attr_proxy attr(const char*) { return {}; }

  template<typename... Args>
  module_ def_submodule(Args&&...) { return {}; }

  template<typename... Args>
  module_& def(Args&&...) { return *this; }
};

template<typename... Args>
struct init {};

template<typename T>
struct class_ {
  class_(module_, const char*) {}

  template<typename... Args>
  class_& def(Args&&...) { return *this; }

  template<typename... Args>
  class_& def_rw(Args&&...) { return *this; }

  template<typename... Args>
  class_& def_ro(Args&&...) { return *this; }
};

template<typename T>
struct enum_ {
  enum_(module_, const char*) {}

  template<typename... Args>
  enum_& value(Args&&...) { return *this; }

  enum_& export_values() { return *this; }
};

template<typename... Args>
struct overload_cast_impl {
  template<typename Return>
  constexpr auto operator()(Return (*fn)(Args...)) const -> decltype(fn) {
    return fn;
  }

  template<typename Return, typename Class>
  constexpr auto operator()(Return (Class::*fn)(Args...)) const -> decltype(fn) {
    return fn;
  }

  template<typename Return, typename Class>
  constexpr auto operator()(Return (Class::*fn)(Args...) const) const -> decltype(fn) {
    return fn;
  }
};

template<typename... Args>
constexpr overload_cast_impl<Args...> overload_cast {};

template<typename... Guards>
struct call_guard {};

struct gil_scoped_release {};

struct self_t {};
inline constexpr self_t self {};
inline int operator==(self_t, self_t) { return 0; }
inline int operator!=(self_t, self_t) { return 0; }

namespace detail {
template<typename T>
struct type_caster {};

template<typename T>
struct make_caster {
  using Map = T;
  using DMap = T;
  static constexpr const char* Name = "";

  bool from_python(handle, uint8_t, cleanup_list*) { return false; }

  template<typename U>
  bool can_cast() const { return false; }

  struct inner_caster {
    struct value_t {
      bool is_valid() const { return false; }
    } value;
    operator Map() const { return *static_cast<Map*>(nullptr); }
  } caster;

  struct dependent_caster {
    inner_caster caster;
    operator DMap() const { return *static_cast<DMap*>(nullptr); }
  } dcaster;

  template<typename U>
  static handle from_cpp(U&&, rv_policy, cleanup_list*) { return {}; }
};

inline const char* optional_name(const char*) { return ""; }

template<typename T>
uint8_t flags_for_local_caster(uint8_t flags) { return flags; }

template<typename Like, typename T>
decltype(auto) forward_like_(T&& value) {
  return std::forward<T>(value);
}
}

template<typename T>
class_<T> bind_vector(module_ m, const char* name) {
  return class_<T>(m, name);
}
}
#endif
"""
  writeAstStub(result / "nanobind" / "nanobind.h", nanobindStub)
  for rel in ["eigen/dense.h", "eigen/sparse.h", "stl/string.h",
              "stl/bind_vector.h", "stl/optional.h", "operators.h"]:
    writeAstStub(result / "nanobind" / rel,
                 "#ifndef NANOBIND_AST_STUB_" & cIdent(rel).toUpperAscii & "\n" &
                 "#define NANOBIND_AST_STUB_" & cIdent(rel).toUpperAscii & "\n" &
                 "#include <nanobind/nanobind.h>\n" &
                 "#endif\n")

proc clangCommand(cfg: Config; input: string; dumpAst: bool; astFilter = ""): string =
  var args = @[
    cfg.clangExe,
    "-std=" & cfg.cppStd,
    "-include", "cstring",
    "-fsyntax-only",
    "-DPYTHON_MODULE_NAME=" & cfg.moduleName,
    "-I" & cfg.projectRoot / "include",
    "-I" & cfg.bindingsDir / "src",
    "-I" & cfg.bindingsDir / "external" / "nanobind" / "include",
    "-I" & cfg.projectRoot / "external" / "cereal" / "include",
    "-I/usr/include/eigen3"
  ]
  let astStubDir = ensureAstStubs(cfg)
  if astStubDir.len > 0:
    args.add "-I" & astStubDir
  if dumpAst:
    args.insert("-ast-dump=json", 2)
    args.insert("-Xclang", 2)
    if astFilter.len > 0:
      args.insert("-ast-dump-filter=" & astFilter, 4)
      args.insert("-Xclang", 4)
  if cfg.pythonIncludes:
    args.add readPythonConfigIncludes()
  let nanobindInclude = readNanobindInclude()
  if nanobindInclude.len > 0:
    args.add "-I" & nanobindInclude
  args.add cfg.clangArgs
  args.add input
  args.mapIt(quoteShell(it)).join(" ")

proc parseAst(cfg: Config): seq[JsonNode] =
  if cfg.astJson.len > 0:
    let text = if cfg.astJson == "-": stdin.readAll else: readFile(cfg.astJson)
    return parseJsonObjects(text)

  if cfg.inputs.len == 0:
    quit "no input files; pass --input or --ast-json", 2

  for input in cfg.inputs:
    let checkCmd = clangCommand(cfg, input, dumpAst = false)
    if cfg.verbose:
      stderr.writeLine checkCmd
    let checkRes = execCmdEx(checkCmd, options = {poUsePath, poStdErrToStdOut})
    if checkRes.exitCode != 0:
      var diagnostics = checkRes.output.strip
      if diagnostics.len > 4000:
        diagnostics = diagnostics[0 ..< 4000] & "\n... truncated ..."
      stderr.writeLine diagnostics
      quit "clang++ syntax check failed for " & input, checkRes.exitCode

    let filters = if cfg.astFilters.len == 0: @[""] else: cfg.astFilters
    for astFilter in filters:
      let cmd = clangCommand(cfg, input, dumpAst = true, astFilter = astFilter)
      if cfg.verbose:
        stderr.writeLine cmd
      let res = execCmdEx(cmd, options = {poUsePath, poStdErrToStdOut})
      if res.exitCode != 0:
        let jsonStart = res.output.find("\n{")
        var diagnostics =
          if jsonStart >= 0: res.output[0 ..< jsonStart].strip
          else: res.output.strip
        if diagnostics.len == 0:
          diagnostics = res.output[0 ..< min(res.output.len, 4000)]
        elif diagnostics.len > 4000:
          diagnostics = diagnostics[0 ..< 4000] & "\n... truncated ..."
        stderr.writeLine diagnostics
        quit "clang++ AST dump failed for " & input, res.exitCode
      try:
        result.add parseJsonObjects(res.output)
      except JsonParsingError as e:
        let jsonStart = res.output.find("\n{")
        let sample =
          if jsonStart > 0: res.output[0 ..< min(jsonStart, 4000)]
          else: res.output[0 ..< min(res.output.len, 4000)]
        stderr.writeLine sample
        quit "clang++ output was not valid JSON for " & input & ": " & e.msg, 1

proc typeLeaf(t: string): string =
  let clean = cleanupType(t)
  let p = clean.rfind("::")
  if p >= 0:
    clean[p + 2 .. ^1]
  else:
    clean

proc equivalentTypes(a, b: string): bool =
  let aa = cleanupType(a).replace(" ", "")
  let bb = cleanupType(b).replace(" ", "")
  aa == bb or typeLeaf(aa) == typeLeaf(bb)

proc collectClasses(c: var GenContext): seq[ClassBinding] =
  for _, cls in c.model.classes:
    result.add cls
  result.sort(proc(a, b: ClassBinding): int = cmp(a.cName, b.cName))

proc collectEnums(c: var GenContext): seq[EnumBinding] =
  for _, en in c.model.enums:
    result.add en
  result.sort(proc(a, b: EnumBinding): int = cmp(a.cName, b.cName))

proc isDocNameCandidate(name: string): bool =
  let s = name.strip
  if s.len < 4:
    return false
  if s.startsWith("__"):
    return false
  for ch in s:
    if ch == '_' or ch == ':' or ch == '<' or ch.isUpperAscii:
      return true
  false

proc addDocNameMapping(c: var GenContext; oldName, newName: string;
                       relatedAccessors = false) =
  let old = oldName.strip
  let mapped = newName.strip
  if old.len == 0 or mapped.len == 0 or old == mapped:
    return
  if not isDocNameCandidate(old):
    return
  var names = c.docNameMap.getOrDefault(old, @[])
  if mapped notin names:
    names.add mapped
    c.docNameMap[old] = names
  if relatedAccessors:
    c.docNameRelatedAccessors.incl old

proc addDocNameMappings(c: var GenContext; oldNames: openArray[string];
                        newName: string; relatedAccessors = false) =
  for oldName in oldNames:
    c.addDocNameMapping(oldName, newName, relatedAccessors)

proc methodCName(cls: ClassBinding; meth: MethodBinding;
                 methodCounts: var Table[string, int]): string =
  let baseName = cls.cName & "_" & cIdent(meth.pyName)
  let count = methodCounts.getOrDefault(baseName, 0) + 1
  methodCounts[baseName] = count
  baseName & (if count == 1: "" else: "_" & $count)

proc moduleFunctionCName(c: var GenContext; f: ModuleFunctionBinding;
                         moduleCounts: var Table[string, int]): string =
  let baseName = c.cfg.cPrefix & "_module_" & cIdent(f.pyName)
  let count = moduleCounts.getOrDefault(baseName, 0) + 1
  moduleCounts[baseName] = count
  baseName & (if count == 1: "" else: "_" & $count)

proc isIdentChar(ch: char): bool =
  ch.isAlphaNumeric or ch == '_'

proc hasDocRefBoundary(s: string; pos, len: int): bool =
  let beforeOk = pos == 0 or not isIdentChar(s[pos - 1])
  let afterPos = pos + len
  let afterOk = afterPos >= s.len or not isIdentChar(s[afterPos])
  beforeOk and afterOk

proc replaceDocRef(doc, oldName, annotation: string; ownLine = false): string =
  let marker = " (BYGEN: "
  var pos = 0
  result = ""
  while pos < doc.len:
    let rel = doc.find(oldName, pos)
    if rel < 0:
      result.add doc[pos .. ^1]
      break
    result.add doc[pos ..< rel]
    let alreadyAnnotated =
      rel + oldName.len + marker.len <= doc.len and
      doc[rel + oldName.len ..< rel + oldName.len + marker.len] == marker
    if hasDocRefBoundary(doc, rel, oldName.len) and not alreadyAnnotated:
      if ownLine:
        result.add oldName & "\n(BYGEN: " & annotation & ")"
      else:
        result.add oldName & marker & annotation & ")"
    else:
      result.add oldName
    pos = rel + oldName.len

proc docRefCandidates(doc: string): seq[string] =
  var i = 0
  while i < doc.len:
    if not (doc[i].isAlphaAscii or doc[i] == '_'):
      inc i
      continue
    let start = i
    inc i
    while i < doc.len and (doc[i].isAlphaNumeric or doc[i] in {'_', ':'}):
      inc i
    let candidate = doc[start ..< i]
    if isDocNameCandidate(candidate) and "_" in candidate and
       candidate notin result:
      result.add candidate

proc annotateDocRefs(c: var GenContext; doc: string;
                     relatedAccessors: seq[string] = @[]): string =
  result = doc
  var names: seq[string]
  for oldName, _ in c.docNameMap:
    names.add oldName
  names.sort(proc(a, b: string): int =
    let byLen = cmp(b.len, a.len)
    if byLen != 0: byLen else: cmp(a, b))
  for oldName in names:
    let annotation =
      if oldName in c.docNameRelatedAccessors:
        "no `" & oldName & "` found, see related accessors " &
        c.docNameMap[oldName].join(", ")
      else:
        "mapped into " & c.docNameMap[oldName].join(", ")
    result = replaceDocRef(result, oldName, annotation,
                           ownLine = oldName in c.docNameRelatedAccessors)
  if relatedAccessors.len > 0:
    for oldName in docRefCandidates(doc):
      if not c.docNameMap.hasKey(oldName):
        result = replaceDocRef(
          result,
          oldName,
          "no `" & oldName & "` found, see related accessors " &
          relatedAccessors.join(", "),
          ownLine = true)

proc wrappedDocLines(doc: string; width = 76): seq[string] =
  let normalized = doc.replace("\r\n", "\n").replace("\r", "\n").strip
  if normalized.len == 0:
    return
  for rawLine in normalized.splitLines:
    let words = rawLine.splitWhitespace
    if words.len == 0:
      result.add ""
      continue
    var line = ""
    for word in words:
      if line.len == 0:
        line = word
      elif line.len + 1 + word.len <= width:
        line.add " " & word
      else:
        result.add line
        line = word
    if line.len > 0:
      result.add line

proc commentBlock(c: var GenContext; doc: string; indent = "";
                  relatedAccessors: seq[string] = @[]): seq[string] =
  let lines = wrappedDocLines(c.annotateDocRefs(doc, relatedAccessors))
  if lines.len == 0:
    return
  if lines.len == 1:
    result.add indent & "/* " & lines[0] & " */"
    return
  result.add indent & "/* " & lines[0]
  for i in 1 ..< lines.len:
    result.add indent & "   " & lines[i]
  result[^1].add " */"

proc addHeaderComment(c: var GenContext; lines: var seq[string]; doc: string;
                      indent = ""; relatedAccessors: seq[string] = @[]) =
  let commentLines = c.commentBlock(doc, indent, relatedAccessors)
  if commentLines.len == 0:
    return
  for line in commentLines:
    lines.add line

proc assignCNames(model: var Model; prefix: string) =
  var used = initHashSet[string]()
  for _, en in model.enums.mpairs:
    var base = makeCName(prefix, en.cppType)
    var name = base
    var i = 2
    while name in used:
      name = base & "_" & $i
      inc i
    en.cName = name
    used.incl name
  for _, cls in model.classes.mpairs:
    var base = makeCName(prefix, cls.cppType)
    var name = base
    var i = 2
    while name in used:
      name = base & "_" & $i
      inc i
    cls.cName = name
    used.incl name

proc mapSimpleScalar(cppType: string): string =
  let clean = cleanupType(cppType).replace("std::", "")
  case clean
  of "void":
    "void"
  of "bool":
    "bool"
  of "float", "f32", "c_float", "proxsuite::linalg::veg::f32":
    "float"
  of "double", "f64", "c_double", "proxsuite::linalg::veg::f64":
    "double"
  of "char":
    "char"
  of "signed char", "int8_t", "proxsuite::linalg::veg::i8":
    "int8_t"
  of "unsigned char", "uint8_t", "proxsuite::linalg::veg::u8":
    "uint8_t"
  of "short", "short int", "int16_t", "proxsuite::linalg::veg::i16":
    "int16_t"
  of "unsigned short", "unsigned short int", "uint16_t",
     "proxsuite::linalg::veg::u16":
    "uint16_t"
  of "int", "signed int", "int32_t", "proxsuite::linalg::veg::i32":
    "int32_t"
  of "unsigned", "unsigned int", "uint32_t", "proxsuite::linalg::veg::u32":
    "uint32_t"
  of "long", "long int":
    "long"
  of "unsigned long", "long unsigned int":
    "unsigned long"
  of "long long", "long long int", "int64_t", "i64",
     "proxsuite::linalg::veg::i64":
    "int64_t"
  of "unsigned long long", "long long unsigned int", "uint64_t", "u64",
     "proxsuite::linalg::veg::u64":
    "uint64_t"
  of "size_t":
    "int64_t"
  of "isize", "dense::isize", "sparse::isize", "proxqp::isize",
     "proxsuite::proxqp::dense::isize", "proxsuite::proxqp::sparse::isize",
     "proxsuite::linalg::veg::isize", "std::ptrdiff_t":
    "int64_t"
  else:
    ""

proc findClassForType(c: var GenContext; cppType: string): ClassBinding =
  let stripped = stripCvRef(cppType)
  for _, cls in c.model.classes:
    if equivalentTypes(stripped.base, cls.cppType):
      return cls

proc findEnumForType(c: var GenContext; cppType: string): EnumBinding =
  let stripped = stripCvRef(cppType)
  for _, en in c.model.enums:
    if equivalentTypes(stripped.base, en.cppType):
      return en

proc compactTypeName(t: string): string =
  cleanupType(t).replace(" ", "")

proc mapFieldViewType(cppType: string): FieldViewMap =
  let base = cleanupType(stripCvRef(cppType).base)
  let compact = compactTypeName(base)
  let leaf = typeLeaf(base)

  if "linalg::veg::Vec" in base:
    return

  if base in ["Vec<double>", "dense::Vec<double>", "sparse::Vec<double>",
              "VectorType",
              "proxsuite::proxqp::dense::Vec<double>",
              "proxsuite::proxqp::sparse::Vec<double>"] or
     leaf == "Vec<double>" or
     compact.startsWith("Eigen::Matrix<double,-1,1") or
     compact.startsWith("Eigen::Matrix<double,Eigen::Dynamic,1"):
    result.ok = true
    result.cType = "proxsuite_c_dense_vector_double"
    result.kind = fvkDenseVectorDouble
    return

  if base in ["Mat<double>", "dense::Mat<double>",
              "Mat",
              "proxsuite::proxqp::dense::Mat<double>",
              "Mat<double, 1>", "dense::Mat<double, 1>",
              "proxsuite::proxqp::dense::Mat<double, 1>"] or
     leaf in ["Mat<double>", "Mat<double, 1>"] or
     compact.endsWith("BackwardData<double>::Mat") or
     compact.startsWith("Eigen::Matrix<double,-1,-1") or
     compact.startsWith("Eigen::Matrix<double,Eigen::Dynamic,Eigen::Dynamic"):
    result.ok = true
    result.cType = "proxsuite_c_dense_matrix_double"
    result.kind = fvkDenseMatrixDouble
    return

  if base in ["SparseMat<double, int>", "sparse::SparseMat<double, int>",
              "proxsuite::proxqp::sparse::SparseMat<double, int>"] or
     compact.startsWith("Eigen::SparseMatrix<double"):
    result.ok = true
    result.cType = "proxsuite_c_sparse_matrix_double_int"
    result.kind = fvkSparseMatrixDoubleInt
    return

  if base in ["SparseMat<bool, int>", "sparse::SparseMat<bool, int>",
              "proxsuite::proxqp::sparse::SparseMat<bool, int>"] or
     compact.startsWith("Eigen::SparseMatrix<bool"):
    result.ok = true
    result.cType = "proxsuite_c_sparse_matrix_bool_int"
    result.kind = fvkSparseMatrixBoolInt
    return

proc mapCType(c: var GenContext; cppType: string; forReturn = false): TypeMap =
  let stripped = stripCvRef(cppType)
  result.cppType = stripped.base
  result.byRef = stripped.byRef
  result.isConst = stripped.isConst

  var optionalArgs: seq[string]
  for marker in ["optional<", "std::optional<", "proxsuite::optional<"]:
    optionalArgs = templateArgsAfter(stripped.base, marker)
    if optionalArgs.len > 0:
      break
  if optionalArgs.len == 1:
    let inner = cleanupType(optionalArgs[0])
    result.ok = true
    result.isOptional = true
    result.cppType = stripped.base
    if inner in ["double", "f64", "proxsuite::linalg::veg::f64"]:
      result.cType = "const double*"
      result.castHelper = "proxsuite_c_optional_double_from_c"
      return
    if inner == "bool":
      result.cType = "const bool*"
      result.castHelper = "proxsuite_c_optional_bool_from_c"
      return
    if inner in ["isize", "dense::isize", "sparse::isize", "proxqp::isize",
                 "proxsuite::proxqp::dense::isize",
                 "proxsuite::proxqp::sparse::isize",
                 "proxsuite::linalg::veg::isize"]:
      result.cType = "const int64_t*"
      result.castHelper = "proxsuite_c_optional_isize_from_c"
      return
    if inner in ["MatRef<double>", "dense::MatRef<double>",
                 "proxsuite::proxqp::dense::MatRef<double>"]:
      result.cType = "const proxsuite_c_dense_matrix_double*"
      result.castHelper = "proxsuite_c_optional_dense_mat_ref_double_from_c"
      return
    if inner in ["VecRef<double>", "dense::VecRef<double>",
                 "sparse::VecRef<double>",
                 "proxsuite::proxqp::dense::VecRef<double>",
                 "proxsuite::proxqp::sparse::VecRef<double>"]:
      result.cType = "const proxsuite_c_dense_vector_double*"
      result.castHelper = "proxsuite_c_optional_dense_vec_ref_double_from_c"
      return
    if inner in ["SparseMat<double, int>", "sparse::SparseMat<double, int>",
                 "proxsuite::proxqp::sparse::SparseMat<double, int>"]:
      result.cType = "const proxsuite_c_sparse_matrix_double_int*"
      result.castHelper = "proxsuite_c_optional_sparse_mat_double_int_from_c"
      return
    result.ok = false
    return

  let denseMatrixRefTypes = [
    "MatRef<double>",
    "dense::MatRef<double>",
    "proxsuite::proxqp::dense::MatRef<double>"
  ]
  if stripped.base in denseMatrixRefTypes or
     (stripped.base.startsWith("Eigen::MatrixBase<") and
      "Eigen::Matrix<double" in stripped.base):
    result.ok = true
    result.cType = "const proxsuite_c_dense_matrix_double*"
    result.castHelper = "proxsuite_c_dense_mat_double_from_c"
    result.needsLocal = true
    return

  let sparseDoubleTypes = [
    "SparseMat<double, int>",
    "sparse::SparseMat<double, int>",
    "proxsuite::proxqp::sparse::SparseMat<double, int>"
  ]
  if stripped.base in sparseDoubleTypes:
    result.ok = true
    result.cType = "const proxsuite_c_sparse_matrix_double_int*"
    result.castHelper = "proxsuite_c_sparse_mat_double_int_from_c"
    result.needsLocal = true
    return

  let sparseBoolTypes = [
    "SparseMat<bool, int>",
    "sparse::SparseMat<bool, int>",
    "proxsuite::proxqp::sparse::SparseMat<bool, int>"
  ]
  if stripped.base in sparseBoolTypes:
    result.ok = true
    result.cType = "const proxsuite_c_sparse_matrix_bool_int*"
    result.castHelper = "proxsuite_c_sparse_mat_bool_int_from_c"
    result.needsLocal = true
    return

  let scalar = mapSimpleScalar(stripped.base)
  if scalar.len > 0:
    result.ok = true
    result.cType = scalar
    result.isVoid = scalar == "void"
    return

  if cleanupType(stripped.base) in ["std::string", "string"]:
    result.ok = true
    result.isString = true
    result.cType = if forReturn: "char*" else: "const char*"
    return

  let en = c.findEnumForType(stripped.base)
  if en != nil:
    result.ok = true
    result.cppType = en.cppType
    result.cType = en.cName
    result.isEnum = true
    return

  let cls = c.findClassForType(stripped.base)
  if cls != nil:
    result.ok = true
    result.cppType = cls.cppType
    result.isClass = true
    result.className = cls.cName
    result.cType = (if forReturn: cls.cName & "*" else:
                    (if stripped.isConst: "const " else: "") & cls.cName & "*")
    return

proc fieldCNames(c: var GenContext; cls: ClassBinding;
                 field: FieldBinding): seq[string] =
  let suffix = cIdent(field.pyName)
  let vm = mapFieldViewType(field.cppType)
  if vm.ok:
    result.add cls.cName & "_get_" & suffix
    return
  let tm = c.mapCType(field.cppType)
  if tm.isClass:
    result.add cls.cName & "_get_" & suffix
  elif tm.ok and not tm.isVoid:
    result.add cls.cName & "_get_" & suffix
    if not field.readonly:
      result.add cls.cName & "_set_" & suffix
  else:
    result.add cls.cName & "_get_" & suffix & "_ptr"
    if not field.readonly:
      result.add cls.cName & "_get_" & suffix & "_mut"

proc prepareDocNameMappings(c: var GenContext) =
  for en in c.collectEnums():
    c.addDocNameMappings([en.pyName, en.cppType, typeLeaf(en.cppType)], en.cName)
    for val in en.values:
      c.addDocNameMappings([val.pyName, val.cppName],
                           (en.cName & "_" & cIdent(val.pyName)).toUpperAscii)

  for cls in c.collectClasses():
    c.addDocNameMappings([cls.pyName, cls.cppType, typeLeaf(cls.cppType)], cls.cName)
    for field in cls.fields:
      let mapped = c.fieldCNames(cls, field).join(", ")
      c.addDocNameMappings([field.pyName, field.cppName], mapped,
                           relatedAccessors = true)

    var methodCounts = initTable[string, int]()
    for meth in cls.methods:
      let mapped = methodCName(cls, meth, methodCounts)
      c.addDocNameMappings([meth.pyName, meth.cppName], mapped)

  var moduleCounts = initTable[string, int]()
  for f in c.model.moduleFunctions:
    let mapped = c.moduleFunctionCName(f, moduleCounts)
    c.addDocNameMappings([f.pyName, f.cppName], mapped)

proc contextCName(c: var GenContext): string =
  c.cfg.cPrefix & "_context"

proc errorCodeCName(c: var GenContext): string =
  c.cfg.cPrefix & "_error_code"

proc cEnumPrefix(c: var GenContext): string =
  c.cfg.cPrefix.toUpperAscii

proc zeroValue(c: var GenContext; cType: string): string =
  if cType == "void":
    ""
  elif cType.endsWith("*"):
    "nullptr"
  elif cType == "bool":
    "false"
  elif cType == "proxsuite_c_dense_vector_double":
    "proxsuite_c_dense_vector_double{nullptr, 0}"
  elif cType == "proxsuite_c_dense_matrix_double":
    "proxsuite_c_dense_matrix_double{nullptr, 0, 0}"
  elif cType == "proxsuite_c_sparse_matrix_double_int":
    "proxsuite_c_sparse_matrix_double_int{0, 0, 0, nullptr, nullptr, nullptr}"
  elif cType == "proxsuite_c_sparse_matrix_bool_int":
    "proxsuite_c_sparse_matrix_bool_int{0, 0, 0, nullptr, nullptr, nullptr}"
  else:
    "(" & cType & ")0"

proc fieldViewZero(vm: FieldViewMap): string =
  case vm.kind
  of fvkDenseVectorDouble:
    "proxsuite_c_dense_vector_double{nullptr, 0}"
  of fvkDenseMatrixDouble:
    "proxsuite_c_dense_matrix_double{nullptr, 0, 0}"
  of fvkSparseMatrixDoubleInt:
    "proxsuite_c_sparse_matrix_double_int{0, 0, 0, nullptr, nullptr, nullptr}"
  of fvkSparseMatrixBoolInt:
    "proxsuite_c_sparse_matrix_bool_int{0, 0, 0, nullptr, nullptr, nullptr}"
  of fvkNone:
    "{}"

proc fieldViewExpr(vm: FieldViewMap; expr: string): string =
  case vm.kind
  of fvkDenseVectorDouble:
    "proxsuite_c_dense_vector_double{" & expr & ".data(), static_cast<int64_t>(" &
    expr & ".size())}"
  of fvkDenseMatrixDouble:
    "proxsuite_c_dense_matrix_double{" & expr & ".data(), static_cast<int64_t>(" &
    expr & ".rows()), static_cast<int64_t>(" & expr & ".cols())}"
  of fvkSparseMatrixDoubleInt:
    "proxsuite_c_sparse_matrix_double_int{static_cast<int64_t>(" & expr &
    ".rows()), static_cast<int64_t>(" & expr & ".cols()), static_cast<int64_t>(" &
    expr & ".nonZeros()), " & expr & ".outerIndexPtr(), " & expr &
    ".innerIndexPtr(), " & expr & ".valuePtr()}"
  of fvkSparseMatrixBoolInt:
    "proxsuite_c_sparse_matrix_bool_int{static_cast<int64_t>(" & expr &
    ".rows()), static_cast<int64_t>(" & expr & ".cols()), static_cast<int64_t>(" &
    expr & ".nonZeros()), " & expr & ".outerIndexPtr(), " & expr &
    ".innerIndexPtr(), " & expr & ".valuePtr()}"
  of fvkNone:
    "{}"

proc cHandleCast(cName, expr: string): string =
  "reinterpret_cast<" & cName & "*>(" & expr & ")"

proc cppHandleCast(cppType, expr: string; isConst = false): string =
  "reinterpret_cast<" & (if isConst: "const " else: "") & cppType & "*>(" &
    expr & ")"

proc selfPtrDecl(cls: ClassBinding; isConst = false): string =
  "  auto* ptr{" & cppHandleCast(cls.cppType, "self", isConst) & "};"

proc cppCastExpr(c: var GenContext; tm: TypeMap; varName: string): string =
  if tm.isOptional:
    return tm.castHelper & "(" & varName & ")"
  if tm.castHelper.len > 0:
    return tm.castHelper & "(" & varName & ")"
  if tm.isClass:
    return "*" & cppHandleCast(tm.cppType, varName, tm.isConst)
  if tm.isEnum:
    return "static_cast<" & tm.cppType & ">(" & varName & ")"
  if tm.isString:
    return "std::string{" & varName & " == nullptr ? \"\" : " & varName & "}"
  if tm.cType == tm.cppType or tm.cType == "void":
    return varName
  "static_cast<" & tm.cppType & ">(" & varName & ")"

proc returnExpr(c: var GenContext; tm: TypeMap; expr: string): string =
  if tm.isVoid:
    expr & ";"
  elif tm.isClass:
    if tm.byRef:
      "auto& ref{" & expr & "};\n  return " & cHandleCast(tm.className, "&ref") & ";"
    else:
      "auto value{" & expr & "};\n  return " & cHandleCast(tm.className,
        "new " & tm.cppType & "{std::move(value)}") & ";"
  elif tm.isEnum:
    "return static_cast<" & tm.cType & ">(" & expr & ");"
  elif tm.isString:
    "auto value{" & expr & "};\n" &
    "  auto* out{static_cast<char*>(std::malloc(value.size() + 1))};\n" &
    "  if (out == nullptr) return nullptr;\n" &
    "  std::memcpy(out, value.c_str(), value.size() + 1);\n" &
    "  return out;"
  elif tm.cType == tm.cppType:
    "return " & expr & ";"
  else:
    "return static_cast<" & tm.cType & ">(" & expr & ");"

proc isCReservedName(c: var GenContext; name: string): bool =
  if name in ["alignas", "alignof", "auto", "bool", "break", "case",
              "char", "const", "constexpr", "continue", "default", "do",
              "double", "else", "enum", "extern", "false", "float", "for",
              "goto", "if", "inline", "int", "long", "nullptr", "register",
              "restrict", "return", "short", "signed", "sizeof", "static",
              "static_assert", "struct", "switch", "thread_local", "true",
              "typedef", "typeof", "typeof_unqual", "union", "unsigned",
              "void", "volatile", "while", "_Alignas", "_Alignof", "_Atomic",
              "_BitInt", "_Bool", "_Complex", "_Decimal128", "_Decimal32",
              "_Decimal64", "_Generic", "_Imaginary", "_Noreturn",
              "_Static_assert", "_Thread_local", "asm", "fortran"]:
    return true
  name.len >= 2 and name[0] == '_' and (name[1] == '_' or name[1].isUpperAscii)

proc makeParamName(c: var GenContext; names: seq[string]; index: int;
                   used: var HashSet[string]): string =
  var base = ""
  if index < names.len and names[index].strip.len > 0:
    base = cIdent(names[index])
  if base.len == 0:
    base = "arg" & $index
  if c.isCReservedName(base):
    base.add "_"
  result = base
  var suffix = 2
  while result in used:
    result = base & "_" & $suffix
    inc suffix
  used.incl result

proc formatDeclType(c: var GenContext; t: string): string =
  var base = t.strip
  var pointerSuffix = ""
  while base.endsWith("*"):
    base = base[0 ..< base.len - 1].strip
    pointerSuffix.add "*"
  if pointerSuffix.len > 0:
    base & " " & pointerSuffix
  else:
    base

proc paramDecl(c: var GenContext; param: (string, string)): string =
  var base = param[0].strip
  var pointerSuffix = ""
  while base.endsWith("*"):
    base = base[0 ..< base.len - 1].strip
    pointerSuffix.add "*"
  if pointerSuffix.len > 0:
    base & " " & pointerSuffix & param[1]
  else:
    base & " " & param[1]

proc functionParamLines(c: var GenContext; name: string; params: seq[(string, string)]): string =
  let prefix = name & " ("
  result.add prefix
  if params.len == 0:
    result.add "void"
    return
  result.add c.paramDecl(params[0])
  if params.len == 1:
    return
  let indent = " ".repeat(prefix.len)
  for i in 1 ..< params.len:
    result.add ",\n" & indent & c.paramDecl(params[i])

proc prototype(c: var GenContext; retType, name: string; params: seq[(string, string)]): string =
  "extern " & c.formatDeclType(retType) & "\n" &
  c.functionParamLines(name, params) & ");"

proc definitionStart(c: var GenContext; retType, name: string; params: seq[(string, string)]): string =
  c.formatDeclType(retType) & "\n" &
  c.functionParamLines(name, params) & ")\n" &
  "{"

proc indentLines(text, prefix: string): string =
  for line in text.splitLines:
    result.add prefix & line & "\n"
  if result.len > 0:
    result.setLen(result.len - 1)

proc exceptionReturnStmt(c: var GenContext; retType: string): string =
  if retType == "void":
    "return;"
  else:
    "return " & c.zeroValue(retType) & ";"

proc wrapExceptionHandling(c: var GenContext; retType, body: string): string =
  let ret = c.exceptionReturnStmt(retType)
  result.add "  " & c.cfg.cPrefix & "_context_begin_call(ctx);\n"
  result.add "  try {\n"
  result.add indentLines(body, "  ")
  result.add "\n"
  result.add "  }\n"
  result.add "  catch (const std::bad_alloc& e) {\n"
  result.add "    " & c.cfg.cPrefix &
             "_context_set_error(ctx, " & c.cEnumPrefix &
             "_BAD_ALLOC, e.what());\n"
  result.add "    " & ret & "\n"
  result.add "  }\n"
  result.add "  catch (const std::invalid_argument& e) {\n"
  result.add "    " & c.cfg.cPrefix &
             "_context_set_error(ctx, " & c.cEnumPrefix &
             "_INVALID_ARG, e.what());\n"
  result.add "    " & ret & "\n"
  result.add "  }\n"
  result.add "  catch (const std::exception& e) {\n"
  result.add "    " & c.cfg.cPrefix &
             "_context_set_error(ctx, " & c.cEnumPrefix &
             "_EXCEPTION, e.what());\n"
  result.add "    " & ret & "\n"
  result.add "  }\n"
  result.add "  catch (...) {\n"
  result.add "    " & c.cfg.cPrefix &
             "_context_set_error(ctx, " & c.cEnumPrefix &
             "_UNKNOWN_ERROR, \"unknown C++ exception\");\n"
  result.add "    " & ret & "\n"
  result.add "  }"

proc defaultImplIncludes(c: var GenContext): seq[string] =
  @[
    "proxsuite/proxqp/dense/wrapper.hpp",
    "proxsuite/proxqp/sparse/wrapper.hpp",
    "proxsuite/proxqp/dense/model.hpp",
    "proxsuite/proxqp/sparse/model.hpp",
    "proxsuite/proxqp/dense/workspace.hpp",
    "proxsuite/proxqp/results.hpp",
    "proxsuite/proxqp/settings.hpp",
    "proxsuite/proxqp/status.hpp",
    "proxsuite/helpers/version.hpp",
    "proxsuite/helpers/instruction-set.hpp"
  ]

proc noteCastHelper(c: var GenContext; tm: TypeMap) =
  if tm.castHelper.len > 0:
    c.usedHelpers.incl tm.castHelper

proc addCallArg(c: var GenContext; tm: TypeMap; paramName: string;
                callArgs, preCall: var seq[string]) =
  c.noteCastHelper(tm)
  if tm.needsLocal:
    let localName = paramName & "_value"
    preCall.add "auto " & localName & "{" & c.cppCastExpr(tm, paramName) & "};"
    callArgs.add localName
  else:
    callArgs.add c.cppCastExpr(tm, paramName)

proc addSupportIf(c: var GenContext; outLines: var seq[string];
                  helper: string; lines: openArray[string]) =
  if helper in c.usedHelpers:
    for line in lines:
      outLines.add line
    outLines.add ""

proc supportImpl(c: var GenContext): seq[string] =
  c.addSupportIf(result, "proxsuite_c_optional_double_from_c", [
    "static proxsuite::optional<double>",
    "proxsuite_c_optional_double_from_c(const double* value) {",
    "  if (value == nullptr) return proxsuite::nullopt;",
    "  return *value;",
    "}"
  ])
  c.addSupportIf(result, "proxsuite_c_optional_bool_from_c", [
    "static proxsuite::optional<bool>",
    "proxsuite_c_optional_bool_from_c(const bool* value) {",
    "  if (value == nullptr) return proxsuite::nullopt;",
    "  return *value;",
    "}"
  ])
  c.addSupportIf(result, "proxsuite_c_optional_isize_from_c", [
    "static proxsuite::optional<proxsuite::linalg::veg::isize>",
    "proxsuite_c_optional_isize_from_c(const int64_t* value) {",
    "  if (value == nullptr) return proxsuite::nullopt;",
    "  return static_cast<proxsuite::linalg::veg::isize>(*value);",
    "}"
  ])
  c.addSupportIf(result, "proxsuite_c_dense_mat_double_from_c", [
    "static proxsuite::proxqp::dense::Mat<double>",
    "proxsuite_c_dense_mat_double_from_c(const proxsuite_c_dense_matrix_double* view) {",
    "  using Mat = proxsuite::proxqp::dense::Mat<double>;",
    "  if (view == nullptr || view->data == nullptr) return Mat{};",
    "  using Map = Eigen::Map<const Mat>;",
    "  return Map{view->data, view->rows, view->cols};",
    "}"
  ])
  c.addSupportIf(result, "proxsuite_c_sparse_mat_double_int_from_c", [
    "static proxsuite::proxqp::sparse::SparseMat<double, int>",
    "proxsuite_c_sparse_mat_double_int_from_c(const proxsuite_c_sparse_matrix_double_int* view) {",
    "  using SparseMat = proxsuite::proxqp::sparse::SparseMat<double, int>;",
    "  if (view == nullptr || view->values == nullptr ||",
    "      view->outer_indices == nullptr || view->inner_indices == nullptr) {",
    "    return SparseMat{};",
    "  }",
    "  using Map = Eigen::Map<const SparseMat>;",
    "  Map mapped{static_cast<Eigen::Index>(view->rows),",
    "             static_cast<Eigen::Index>(view->cols),",
    "             static_cast<Eigen::Index>(view->nnz),",
    "             view->outer_indices,",
    "             view->inner_indices,",
    "             view->values};",
    "  return SparseMat{mapped};",
    "}"
  ])
  c.addSupportIf(result, "proxsuite_c_sparse_mat_bool_int_from_c", [
    "static proxsuite::proxqp::sparse::SparseMat<bool, int>",
    "proxsuite_c_sparse_mat_bool_int_from_c(const proxsuite_c_sparse_matrix_bool_int* view) {",
    "  using SparseMat = proxsuite::proxqp::sparse::SparseMat<bool, int>;",
    "  if (view == nullptr || view->values == nullptr ||",
    "      view->outer_indices == nullptr || view->inner_indices == nullptr) {",
    "    return SparseMat{};",
    "  }",
    "  using Map = Eigen::Map<const SparseMat>;",
    "  Map mapped{static_cast<Eigen::Index>(view->rows),",
    "             static_cast<Eigen::Index>(view->cols),",
    "             static_cast<Eigen::Index>(view->nnz),",
    "             view->outer_indices,",
    "             view->inner_indices,",
    "             view->values};",
    "  return SparseMat{mapped};",
    "}"
  ])
  c.addSupportIf(result, "proxsuite_c_optional_dense_mat_ref_double_from_c", [
    "static proxsuite::optional<proxsuite::proxqp::dense::MatRef<double>>",
    "proxsuite_c_optional_dense_mat_ref_double_from_c(const proxsuite_c_dense_matrix_double* view) {",
    "  if (view == nullptr || view->data == nullptr) return proxsuite::nullopt;",
    "  using Mat = proxsuite::proxqp::dense::Mat<double>;",
    "  using Map = Eigen::Map<const Mat>;",
    "  return Map{view->data, view->rows, view->cols};",
    "}"
  ])
  c.addSupportIf(result, "proxsuite_c_optional_dense_vec_ref_double_from_c", [
    "static proxsuite::optional<proxsuite::proxqp::dense::VecRef<double>>",
    "proxsuite_c_optional_dense_vec_ref_double_from_c(const proxsuite_c_dense_vector_double* view) {",
    "  if (view == nullptr || view->data == nullptr) return proxsuite::nullopt;",
    "  using Vec = proxsuite::proxqp::dense::Vec<double>;",
    "  using Map = Eigen::Map<const Vec>;",
    "  return Map{view->data, view->size};",
    "}"
  ])
  c.addSupportIf(result, "proxsuite_c_optional_sparse_mat_double_int_from_c", [
    "static proxsuite::optional<proxsuite::proxqp::sparse::SparseMat<double, int>>",
    "proxsuite_c_optional_sparse_mat_double_int_from_c(const proxsuite_c_sparse_matrix_double_int* view) {",
    "  if (view == nullptr || view->values == nullptr ||",
    "      view->outer_indices == nullptr || view->inner_indices == nullptr) {",
    "    return proxsuite::nullopt;",
    "  }",
    "  using SparseMat = proxsuite::proxqp::sparse::SparseMat<double, int>;",
    "  using Map = Eigen::Map<const SparseMat>;",
    "  Map mapped{static_cast<Eigen::Index>(view->rows),",
    "             static_cast<Eigen::Index>(view->cols),",
    "             static_cast<Eigen::Index>(view->nnz),",
    "             view->outer_indices,",
    "             view->inner_indices,",
    "             view->values};",
    "  return SparseMat{mapped};",
    "}"
  ])

proc initGenContext(cfg: Config; model: Model): GenContext =
  result.cfg = cfg
  result.model = model
  result.skipped = model.skipped
  result.usedHelpers = initHashSet[string]()
  result.docNameRelatedAccessors = initHashSet[string]()

proc emitHeaderPrelude(c: var GenContext) =
  let guard = cIdent(c.cfg.outHeader.extractFilename).toUpperAscii & "_"
  c.header.add "/* Generated by tools/nanobind_cgen.nim. */"
  c.header.add "#ifndef " & guard
  c.header.add "#define " & guard
  c.header.add "#include <stdbool.h>"
  c.header.add "#include <stdint.h>"
  c.header.add ""
  c.header.add "#ifdef __cplusplus"
  c.header.add "extern \"C\" {"
  c.header.add "#endif"
  c.header.add ""
  c.header.add "typedef struct " & c.contextCName & " " & c.contextCName & ";"
  c.header.add ""
  c.header.add "typedef enum " & c.errorCodeCName & " {"
  c.header.add "  " & c.cEnumPrefix & "_OK = 0,"
  c.header.add "  " & c.cEnumPrefix & "_BAD_ALLOC = 1,"
  c.header.add "  " & c.cEnumPrefix & "_INVALID_ARG = 2,"
  c.header.add "  " & c.cEnumPrefix & "_EXCEPTION = 3,"
  c.header.add "  " & c.cEnumPrefix & "_UNKNOWN_ERROR = 4"
  c.header.add "} " & c.errorCodeCName & ";"
  c.header.add ""
  c.header.add "typedef void (*" & c.cfg.cPrefix & "_error_handler)("
  c.header.add "  " & c.contextCName & " *ctx,"
  c.header.add "  " & c.errorCodeCName & " code,"
  c.header.add "  const char *msg,"
  c.header.add "  void *userdata);"
  c.header.add ""
  c.header.add "typedef struct proxsuite_c_dense_matrix_double {"
  c.header.add "  const double* data;"
  c.header.add "  int64_t rows;"
  c.header.add "  int64_t cols;"
  c.header.add "} proxsuite_c_dense_matrix_double;"
  c.header.add ""
  c.header.add "typedef struct proxsuite_c_dense_vector_double {"
  c.header.add "  const double* data;"
  c.header.add "  int64_t size;"
  c.header.add "} proxsuite_c_dense_vector_double;"
  c.header.add ""
  c.header.add "/* NOTE: ProxSuite sparse matrices use CSC format. */"
  c.header.add "typedef struct proxsuite_c_sparse_matrix_double_int {"
  c.header.add "  int64_t rows;"
  c.header.add "  int64_t cols;"
  c.header.add "  int64_t nnz;"
  c.header.add "  const int* outer_indices;"
  c.header.add "  const int* inner_indices;"
  c.header.add "  const double* values;"
  c.header.add "} proxsuite_c_sparse_matrix_double_int;"
  c.header.add ""
  c.header.add "/* NOTE: ProxSuite sparse matrices use CSC format. */"
  c.header.add "typedef struct proxsuite_c_sparse_matrix_bool_int {"
  c.header.add "  int64_t rows;"
  c.header.add "  int64_t cols;"
  c.header.add "  int64_t nnz;"
  c.header.add "  const int* outer_indices;"
  c.header.add "  const int* inner_indices;"
  c.header.add "  const bool* values;"
  c.header.add "} proxsuite_c_sparse_matrix_bool_int;"
  c.header.add ""

proc emitImplPrelude(c: var GenContext) =
  let implDir = if c.cfg.outImpl.parentDir.len == 0: "." else: c.cfg.outImpl.parentDir
  let headerInclude = relativePath(c.cfg.outHeader, implDir)
  c.impl.add "/* Generated by tools/nanobind_cgen.nim. */"
  c.impl.add "#include \"" & headerInclude & "\""
  c.impl.add "#include <cstdlib>"
  c.impl.add "#include <cstring>"
  c.impl.add "#include <new>"
  c.impl.add "#include <stddef.h>"
  c.impl.add "#include <stdexcept>"
  c.impl.add "#include <string>"
  c.impl.add "#include <utility>"
  if c.cfg.defaultImplIncludes:
    for incl in c.defaultImplIncludes():
      c.impl.add "#include <" & incl & ">"
  for incl in c.cfg.implIncludes:
    if incl.startsWith("<") or incl.startsWith("\""):
      c.impl.add "#include " & incl
    else:
      c.impl.add "#include <" & incl & ">"
  c.impl.add ""
  c.impl.add "using namespace proxsuite;"
  c.impl.add "using namespace proxsuite::proxqp;"
  c.impl.add "using namespace proxsuite::proxqp::dense;"
  c.impl.add "using namespace proxsuite::proxqp::sparse;"
  c.impl.add "using namespace proxsuite::helpers;"
  c.impl.add ""
  c.impl.add "struct " & c.contextCName & " {"
  c.impl.add "  " & c.errorCodeCName & " error_code = " & c.cEnumPrefix & "_OK;"
  c.impl.add "  std::string error_msg;"
  c.impl.add "  const char* fallback_msg = nullptr;"
  c.impl.add "  " & c.cfg.cPrefix & "_error_handler error_handler = nullptr;"
  c.impl.add "  void* error_handler_userdata = nullptr;"
  c.impl.add "};"
  c.impl.add ""
  c.impl.add "static const char*"
  c.impl.add c.cfg.cPrefix & "_error_code_default_msg(" & c.errorCodeCName & " code) {"
  c.impl.add "  switch (code) {"
  c.impl.add "  case " & c.cEnumPrefix & "_OK: return nullptr;"
  c.impl.add "  case " & c.cEnumPrefix & "_BAD_ALLOC: return \"memory allocation failed\";"
  c.impl.add "  case " & c.cEnumPrefix & "_INVALID_ARG: return \"invalid argument\";"
  c.impl.add "  case " & c.cEnumPrefix & "_EXCEPTION: return \"C++ exception\";"
  c.impl.add "  case " & c.cEnumPrefix & "_UNKNOWN_ERROR: return \"unknown C++ exception\";"
  c.impl.add "  }"
  c.impl.add "  return \"unknown error code\";"
  c.impl.add "}"
  c.impl.add ""
  c.impl.add "static const char*"
  c.impl.add c.cfg.cPrefix & "_context_current_error_msg(const " &
             c.contextCName & " *ctx) {"
  c.impl.add "  if (ctx == nullptr) return \"proxsuite_c_context is NULL\";"
  c.impl.add "  if (ctx->error_code == " & c.cEnumPrefix & "_OK) return nullptr;"
  c.impl.add "  if (ctx->fallback_msg != nullptr) return ctx->fallback_msg;"
  c.impl.add "  if (!ctx->error_msg.empty()) return ctx->error_msg.c_str();"
  c.impl.add "  return " & c.cfg.cPrefix &
             "_error_code_default_msg(ctx->error_code);"
  c.impl.add "}"
  c.impl.add ""
  c.impl.add "static void"
  c.impl.add c.cfg.cPrefix & "_context_begin_call(" & c.contextCName & " *ctx) {"
  c.impl.add "  if (ctx == nullptr) return;"
  c.impl.add "  ctx->error_code = " & c.cEnumPrefix & "_OK;"
  c.impl.add "  ctx->fallback_msg = nullptr;"
  c.impl.add "}"
  c.impl.add ""
  c.impl.add "static void"
  c.impl.add c.cfg.cPrefix & "_context_set_error(" & c.contextCName & " *ctx,"
  c.impl.add "                              " & c.errorCodeCName & " code,"
  c.impl.add "                              const char* msg) noexcept {"
  c.impl.add "  if (ctx == nullptr) return;"
  c.impl.add "  ctx->error_code = code;"
  c.impl.add "  ctx->fallback_msg = " & c.cfg.cPrefix & "_error_code_default_msg(code);"
  c.impl.add "  try {"
  c.impl.add "    ctx->error_msg = msg == nullptr ? \"\" : msg;"
  c.impl.add "    if (!ctx->error_msg.empty()) ctx->fallback_msg = nullptr;"
  c.impl.add "  }"
  c.impl.add "  catch (...) {"
  c.impl.add "    ctx->error_msg.clear();"
  c.impl.add "  }"
  c.impl.add "  if (ctx->error_handler != nullptr) {"
  c.impl.add "    try {"
  c.impl.add "      ctx->error_handler(ctx,"
  c.impl.add "                         ctx->error_code,"
  c.impl.add "                         " & c.cfg.cPrefix &
             "_context_current_error_msg(ctx),"
  c.impl.add "                         ctx->error_handler_userdata);"
  c.impl.add "    }"
  c.impl.add "    catch (...) {"
  c.impl.add "    }"
  c.impl.add "  }"
  c.impl.add "}"
  c.impl.add ""

proc emitEnums(c: var GenContext) =
  for en in c.collectEnums():
    if en.values.len == 0:
      c.skipped.add en.cppType & " at " & en.loc & ": enum has no collected values"
      continue
    c.addHeaderComment(c.header, en.doc)
    c.header.add "typedef enum " & en.cName & " {"
    for i, val in en.values:
      let comma = if i + 1 < en.values.len: "," else: ""
      c.addHeaderComment(c.header, val.doc, "  ")
      c.header.add "  " & (en.cName & "_" & cIdent(val.pyName)).toUpperAscii & " = " & $i & comma
    c.header.add "} " & en.cName & ";"
    c.header.add ""

proc emitOpaqueStructs(c: var GenContext) =
  for cls in c.collectClasses():
    c.addHeaderComment(c.header, cls.doc)
    c.header.add "typedef struct " & cls.cName & " " & cls.cName & ";"
  if c.model.classes.len > 0:
    c.header.add ""

proc addHeaderDecl(c: var GenContext; doc, decl: string;
                   relatedAccessors: seq[string] = @[]) =
  if c.bodyProtos.len > 0:
    c.bodyProtos.add ""
  let commentLines = c.commentBlock(doc, relatedAccessors = relatedAccessors)
  if commentLines.len > 0:
    for line in commentLines:
      c.bodyProtos.add line
  c.bodyProtos.add decl

proc addFunction(c: var GenContext; retType, name: string;
                 params: seq[(string, string)]; body: string; doc = "";
                 relatedAccessors: seq[string] = @[];
                 withContext = true; catchExceptions = true) =
  var finalParams = params
  if withContext:
    finalParams.insert((c.contextCName & "*", "ctx"), 0)
  let finalBody =
    if withContext and catchExceptions:
      c.wrapExceptionHandling(retType, body)
    else:
      body
  c.addHeaderDecl(doc, c.prototype(retType, name, finalParams), relatedAccessors)
  c.implBody.add c.definitionStart(retType, name, finalParams) & "\n" &
                 finalBody & "\n}"
  inc c.generated

proc emitContextApi(c: var GenContext) =
  c.addFunction(c.contextCName & "*", c.cfg.cPrefix & "_context_create", @[],
                "  try {\n" &
                "    return new " & c.contextCName & "{};\n" &
                "  }\n" &
                "  catch (...) {\n" &
                "    return nullptr;\n" &
                "  }",
                withContext = false,
                catchExceptions = false)
  c.addFunction("void", c.cfg.cPrefix & "_context_destroy",
                @[(c.contextCName & "*", "ctx")],
                "  delete ctx;",
                withContext = false,
                catchExceptions = false)
  c.addFunction("void", c.cfg.cPrefix & "_context_set_error_handler",
                @[(c.contextCName & "*", "ctx"),
                  (c.cfg.cPrefix & "_error_handler", "handler"),
                  ("void*", "userdata")],
                "  if (ctx == nullptr) return;\n" &
                "  ctx->error_handler = handler;\n" &
                "  ctx->error_handler_userdata = userdata;",
                withContext = false,
                catchExceptions = false)
  c.addFunction(c.errorCodeCName, c.cfg.cPrefix & "_context_get_error_code",
                @[("const " & c.contextCName & "*", "ctx")],
                "  if (ctx == nullptr) return " & c.cEnumPrefix &
                "_INVALID_ARG;\n" &
                "  return ctx->error_code;",
                withContext = false,
                catchExceptions = false)
  c.addFunction("const char*", c.cfg.cPrefix & "_context_get_error_msg",
                @[("const " & c.contextCName & "*", "ctx")],
                "  return " & c.cfg.cPrefix &
                "_context_current_error_msg(ctx);",
                withContext = false,
                catchExceptions = false)

proc emitStringFree(c: var GenContext) =
  c.addFunction("void", c.cfg.cPrefix & "_string_free", @[("char*", "value")],
                "  std::free(value);",
                withContext = false,
                catchExceptions = false)

proc emitClassDestroy(c: var GenContext; cls: ClassBinding) =
  c.addFunction("void", cls.cName & "_destroy", @[(cls.cName & "*", "self")],
                "  if (self == nullptr) return;\n" &
                "  delete " & cppHandleCast(cls.cppType, "self") & ";")

proc emitConstructor(c: var GenContext; cls: ClassBinding; overloadIndex: int;
                     ctor: ConstructorBinding) =
  var params: seq[(string, string)] = @[]
  var args: seq[string] = @[]
  var preCall: seq[string] = @[]
  var usedNames = initHashSet[string]()
  usedNames.incl "ctx"
  for j, argType in ctor.args:
    let tm = c.mapCType(argType)
    if not tm.ok or tm.isVoid or tm.isClass:
      c.skipped.add cls.cppType & " constructor at " & ctor.loc &
                    ": unsupported C parameter type '" & argType & "'"
      return
    let name = c.makeParamName(ctor.argNames, j, usedNames)
    params.add (tm.cType, name)
    c.addCallArg(tm, name, args, preCall)

  let fname = cls.cName & "_create" &
              (if overloadIndex == 0: "" else: "_" & $overloadIndex)
  var body = ""
  for line in preCall:
    body.add "  " & line & "\n"
  body.add "  return " & cHandleCast(cls.cName, "new " & cls.cppType &
           "(" & args.join(", ") & ")") & ";"
  c.addFunction(cls.cName & "*", fname, params,
                body.strip(leading = false, trailing = true),
                ctor.doc)

proc emitField(c: var GenContext; cls: ClassBinding; field: FieldBinding) =
  let vm = mapFieldViewType(field.cppType)
  let tm = c.mapCType(field.cppType)
  let suffix = cIdent(field.pyName)
  let relatedAccessors = c.fieldCNames(cls, field)
  if vm.ok:
    let getter = cls.cName & "_get_" & suffix
    c.addFunction(vm.cType, getter, @[("const " & cls.cName & "*", "self")],
                  selfPtrDecl(cls, isConst = true) & "\n" &
                  "  if (ptr == nullptr) return " &
                  fieldViewZero(vm) & ";\n" &
                  "  return " & fieldViewExpr(vm, "ptr->" & field.cppName) & ";",
                  field.doc,
                  relatedAccessors)
  elif tm.isClass:
    let getter = cls.cName & "_get_" & suffix
    c.addFunction(tm.className & "*", getter, @[(cls.cName & "*", "self")],
                  selfPtrDecl(cls) & "\n" &
                  "  if (ptr == nullptr) return nullptr;\n" &
                  "  return " & cHandleCast(tm.className, "&ptr->" & field.cppName) & ";",
                  field.doc,
                  relatedAccessors)
  elif tm.ok and not tm.isVoid:
    let getter = cls.cName & "_get_" & suffix
    c.addFunction(tm.cType, getter, @[("const " & cls.cName & "*", "self")],
                  selfPtrDecl(cls, isConst = true) & "\n" &
                  "  if (ptr == nullptr) return " &
                  c.zeroValue(tm.cType) & ";\n" &
                  "  " & c.returnExpr(tm, "ptr->" & field.cppName),
                  field.doc,
                  relatedAccessors)
    if not field.readonly:
      let setter = cls.cName & "_set_" & suffix
      c.noteCastHelper(tm)
      c.addFunction("void", setter, @[(cls.cName & "*", "self"), (tm.cType, "value")],
                    selfPtrDecl(cls) & "\n" &
                    "  if (ptr == nullptr) return;\n" &
                    "  ptr->" & field.cppName & " = " &
                    c.cppCastExpr(tm, "value") & ";")
  else:
    let ptrGetter = cls.cName & "_get_" & suffix & "_ptr"
    c.addFunction("const void*", ptrGetter, @[( "const " & cls.cName & "*", "self")],
                  selfPtrDecl(cls, isConst = true) & "\n" &
                  "  if (ptr == nullptr) return nullptr;\n" &
                  "  return static_cast<const void*>(&ptr->" & field.cppName & ");",
                  field.doc,
                  relatedAccessors)
    if not field.readonly:
      let mutGetter = cls.cName & "_get_" & suffix & "_mut"
      c.addFunction("void*", mutGetter, @[(cls.cName & "*", "self")],
                    selfPtrDecl(cls) & "\n" &
                    "  if (ptr == nullptr) return nullptr;\n" &
                    "  return static_cast<void*>(&ptr->" & field.cppName & ");")

proc emitMethod(c: var GenContext; cls: ClassBinding; methodCounts: var Table[string, int];
                meth: MethodBinding) =
  let ret = c.mapCType(meth.returnType, forReturn = true)
  if not ret.ok:
    c.skipped.add cls.cppType & "." & meth.pyName & " at " & meth.loc &
                  ": unsupported C return type '" & meth.returnType & "'"
    return

  var params: seq[(string, string)] = @[
    ((if meth.constMethod: "const " else: "") & cls.cName & "*", "self")
  ]
  var callArgs: seq[string] = @[]
  var preCall: seq[string] = @[]
  var usedNames = initHashSet[string]()
  usedNames.incl "ctx"
  usedNames.incl "self"
  for i, p in meth.params:
    let tm = c.mapCType(p)
    if not tm.ok or tm.isVoid:
      c.skipped.add cls.cppType & "." & meth.pyName & " at " & meth.loc &
                    ": unsupported C parameter type '" & p & "'"
      return
    let name = c.makeParamName(meth.argNames, i, usedNames)
    params.add (tm.cType, name)
    c.addCallArg(tm, name, callArgs, preCall)

  let baseName = cls.cName & "_" & cIdent(meth.pyName)
  let count = methodCounts.getOrDefault(baseName, 0) + 1
  methodCounts[baseName] = count
  let fname = baseName & (
    if count == 1: ""
    else: "_" & $count
  )
  let call = "ptr->" & meth.cppName & "(" & callArgs.join(", ") & ")"
  var body = selfPtrDecl(cls, isConst = meth.constMethod) & "\n" &
             "  if (ptr == nullptr)"
  if ret.isVoid:
    body.add " return;\n"
  else:
    body.add " return " & c.zeroValue(ret.cType) & ";\n"
  for line in preCall:
    body.add "  " & line & "\n"
  for line in c.returnExpr(ret, call).splitLines:
    body.add "  " & line & "\n"
  c.addFunction(ret.cType, fname, params,
                body.strip(leading = false, trailing = true),
                meth.doc)

proc emitClass(c: var GenContext; cls: ClassBinding) =
  c.emitClassDestroy(cls)
  for i, ctor in cls.constructors:
    c.emitConstructor(cls, i, ctor)
  for field in cls.fields:
    c.emitField(cls, field)
  var methodCounts = initTable[string, int]()
  for meth in cls.methods:
    c.emitMethod(cls, methodCounts, meth)

proc emitModuleFunction(c: var GenContext; moduleCounts: var Table[string, int];
                        f: ModuleFunctionBinding) =
  let ret = c.mapCType(f.returnType, forReturn = true)
  if not ret.ok or ret.isClass:
    c.skipped.add "module." & f.pyName & " at " & f.loc &
                  ": unsupported C return type '" & f.returnType & "'"
    return

  var params: seq[(string, string)] = @[]
  var callArgs: seq[string] = @[]
  var preCall: seq[string] = @[]
  var usedNames = initHashSet[string]()
  usedNames.incl "ctx"
  for i, p in f.params:
    let tm = c.mapCType(p)
    if not tm.ok or tm.isVoid or tm.isClass:
      c.skipped.add "module." & f.pyName & " at " & f.loc &
                    ": unsupported C parameter type '" & p & "'"
      return
    let name = c.makeParamName(f.argNames, i, usedNames)
    params.add (tm.cType, name)
    c.addCallArg(tm, name, callArgs, preCall)

  let baseName = c.cfg.cPrefix & "_module_" & cIdent(f.pyName)
  let count = moduleCounts.getOrDefault(baseName, 0) + 1
  moduleCounts[baseName] = count
  let fname = baseName & (
    if count == 1: ""
    else: "_" & $count
  )
  var body = ""
  for line in preCall:
    body.add "  " & line & "\n"
  body.add "  " & c.returnExpr(ret, f.cppName & "(" & callArgs.join(", ") & ")")
  c.addFunction(ret.cType, fname, params,
                body.strip(leading = false, trailing = true),
                f.doc)

proc emitModuleFunctions(c: var GenContext) =
  var moduleCounts = initTable[string, int]()
  for f in c.model.moduleFunctions:
    c.emitModuleFunction(moduleCounts, f)

proc finishRender(c: var GenContext): tuple[header, impl: string; generated, skipped: int] =
  c.header.add c.bodyProtos
  c.header.add ""
  c.header.add "#ifdef __cplusplus"
  c.header.add "}"
  c.header.add "#endif"
  c.header.add "#endif"
  c.header.add ""

  c.impl.add c.supportImpl()
  if c.implBody.len > 0:
    c.impl.add "extern \"C\" {"
    c.impl.add c.implBody
    c.impl.add "}"
  if c.skipped.len > 0:
    c.impl.add ""
    c.impl.add "/* Skipped bindings:"
    for item in c.skipped:
      c.impl.add " * - " & item
    c.impl.add " */"
  c.impl.add ""

  result.header = c.header.join("\n")
  result.impl = c.impl.join("\n")
  result.generated = c.generated
  result.skipped = c.skipped.len

proc renderApi(model: Model; cfg: Config): tuple[header, impl: string; generated, skipped: int] =
  var c = initGenContext(cfg, model)
  c.prepareDocNameMappings()
  c.emitHeaderPrelude()
  c.emitImplPrelude()
  c.emitEnums()
  c.emitOpaqueStructs()
  c.emitContextApi()
  c.emitStringFree()
  for cls in c.collectClasses():
    c.emitClass(cls)
  c.emitModuleFunctions()
  c.finishRender()

proc ensureParentDir(path: string) =
  let dir = path.parentDir
  if dir.len > 0 and dir != ".":
    createDir dir

when isMainModule:
  var cfg = parseConfig()
  var model = Model()
  for ast in parseAst(cfg):
    walkAst(ast, model)
  assignCNames(model, cfg.cPrefix)

  let rendered = renderApi(model, cfg)
  ensureParentDir(cfg.outHeader)
  ensureParentDir(cfg.outImpl)
  writeFile(cfg.outHeader, rendered.header)
  writeFile(cfg.outImpl, rendered.impl)

  echo "wrote ", cfg.outHeader
  echo "wrote ", cfg.outImpl
  echo "classes: ", model.classes.len, ", enums: ", model.enums.len,
       ", generated C functions: ", rendered.generated,
       ", skipped bindings: ", rendered.skipped

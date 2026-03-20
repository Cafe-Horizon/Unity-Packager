import std/[os, strutils, times, parseopt, tables, sets]
import zippy, zippy/tarballs

type
  PackagerOptions = object
    inputDir: string
    outputFile: string
    includeDeps: bool

  AssetPaths = tuple[meta: string, asset: string]

proc getGuid(metaPath: string): string =
  try:
    let f = open(metaPath)
    defer: f.close()
    for line in f.lines:
      if line.startsWith("guid: "):
        return line[6..^1].strip()
  except IOError:
    return ""
  return ""

proc extractDependencies(filePath: string): seq[string] =
  var deps = newSeq[string]()
  try:
    let content = readFile(filePath)
    var i = 0
    while i < content.len:
      let idx = content.find("guid: ", i)
      if idx == -1: break
      let guidStart = idx + 6
      if guidStart + 32 <= content.len:
        let possibleGuid = content[guidStart ..< guidStart + 32]
        var isHex = true
        for c in possibleGuid:
          if c notin {'0'..'9', 'a'..'f', 'A'..'F'}:
            isHex = false
            break
        if isHex:
          deps.add(possibleGuid)
      i = idx + 6
  except:
    discard
  return deps

proc findProjectRoot(startDir: string): string =
  var curr = absolutePath(startDir)
  while curr.len > 0:
    if dirExists(curr / "Assets"):
      return curr
    let parent = parentDir(curr)
    if parent == curr: break
    curr = parent
  return ""

proc buildGuidMap(projectRoot: string): Table[string, string] =
  var res = initTable[string, string]()
  if projectRoot == "": return res
  var dirsToVisit = @[projectRoot / "Assets"]
  while dirsToVisit.len > 0:
    let currentDir = dirsToVisit.pop()
    for kind, path in walkDir(currentDir):
      if kind == pcDir:
        dirsToVisit.add(path)
      elif path.endsWith(".meta"):
        let guid = getGuid(path)
        if guid != "":
          res[guid] = path[0 .. ^6]
  return res

proc parseCliArgs(): PackagerOptions =
  var opts = PackagerOptions(includeDeps: false)
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if opts.inputDir == "": opts.inputDir = key
      elif opts.outputFile == "": opts.outputFile = key
    of cmdLongOption, cmdShortOption:
      if key == "dependencies" or key == "d":
        if val == "" or val.toLowerAscii() == "true":
          opts.includeDeps = true
        elif val.toLowerAscii() == "false":
          opts.includeDeps = false
    of cmdEnd: discard

  if opts.inputDir == "" or opts.outputFile == "":
    echo "Usage: packager [options] <inputDir> <outputFile.unitypackage>"
    echo "Options:"
    echo "  -d, --dependencies[=true|false]  Include dependencies (default: false)"
    quit(1)

  opts.inputDir = absolutePath(opts.inputDir)
  opts.outputFile = absolutePath(opts.outputFile)
  return opts

proc collectTargetAssets(inputDir: string, targetGuids: var HashSet[string], guidToPaths: var Table[string, AssetPaths]) =
  var dirsToVisit = @[inputDir]
  while dirsToVisit.len > 0:
    let currentDir = dirsToVisit.pop()
    for kind, path in walkDir(currentDir):
      if kind == pcDir:
        dirsToVisit.add(path)
      if path.endsWith(".meta"):
        let guid = getGuid(path)
        if guid != "":
          let assetPath = path[0 .. ^6]
          if dirExists(assetPath) or fileExists(assetPath):
            targetGuids.incl(guid)
            guidToPaths[guid] = (meta: path, asset: assetPath)

proc resolveDependencies(inputDir: string, targetGuids: var HashSet[string], guidToPaths: var Table[string, AssetPaths]) =
  let projRoot = findProjectRoot(inputDir)
  let globalGuidMap = buildGuidMap(projRoot)
  var queue = newSeq[string]()
  for g in targetGuids: queue.add(g)
  var processed = initHashSet[string]()
  
  while queue.len > 0:
    let currGuid = queue.pop()
    if processed.contains(currGuid): continue
    processed.incl(currGuid)
    
    let paths = guidToPaths.getOrDefault(currGuid, (meta: "", asset: ""))
    let assetPath = paths.asset
    if assetPath != "" and fileExists(assetPath):
      let ext = splitFile(assetPath).ext.toLowerAscii()
      if ext in [".prefab", ".mat", ".unity", ".controller", ".anim", ".asset"]:
        let deps = extractDependencies(assetPath)
        for dGuid in deps:
          if not targetGuids.contains(dGuid) and globalGuidMap.hasKey(dGuid):
            targetGuids.incl(dGuid)
            let dAssetPath = globalGuidMap[dGuid]
            guidToPaths[dGuid] = (meta: dAssetPath & ".meta", asset: dAssetPath)
            queue.add(dGuid)

proc preparePackageTempDir(inputDir: string, tempArchDir: string, targetGuids: HashSet[string], guidToPaths: Table[string, AssetPaths]) =
  for guid in targetGuids:
    let paths = guidToPaths[guid]
    let metaPath = paths.meta
    let assetPath = paths.asset
    let isFile = fileExists(assetPath)
    
    let guidDir = tempArchDir / guid
    createDir(guidDir)
    copyFile(metaPath, guidDir / "asset.meta")
    if isFile:
      copyFile(assetPath, guidDir / "asset")
      
    var relPath = assetPath.replace("\\", "/")
    let assetsIndex = relPath.find("/Assets/")
    var finalPath = ""
    if assetsIndex != -1:
      finalPath = relPath[assetsIndex + 1 .. ^1]
    elif relPath.startsWith("Assets/"):
      finalPath = relPath
    else:
      let parent = parentDir(inputDir)
      finalPath = relativePath(assetPath, parent).replace("\\", "/")
      
    writeFile(guidDir / "pathname", finalPath & "\n")

proc overrideGzipOriginalName(gzData: string, newName: string): string =
  var finalData = gzData[0..2]
  var flg = cast[uint8](gzData[3])
  
  var pos = 10
  if (flg and 0x04) != 0:
    let xlen = cast[int](gzData[pos]) or (cast[int](gzData[pos+1]) shl 8)
    pos += 2 + xlen
  if (flg and 0x08) != 0:
    while gzData[pos] != '\0': pos += 1
    pos += 1
  if (flg and 0x10) != 0:
    while gzData[pos] != '\0': pos += 1
    pos += 1
  if (flg and 0x02) != 0:
    pos += 2
    
  flg = flg or 0x08 # Ensure FNAME flag is set
  finalData.add cast[char](flg)
  finalData.add gzData[4..9]
  finalData.add newName & "\0"
  finalData.add gzData[pos..^1]
  return finalData

proc executePackaging*(opts: PackagerOptions) =
  let tempArchDir = getTempDir() / ("unitypackager_" & $getTime().toUnix())
  let tempTarFile = tempArchDir & ".tar"
  defer:
    if fileExists(tempTarFile): removeFile(tempTarFile)
    if dirExists(tempArchDir): removeDir(tempArchDir)
  createDir(tempArchDir)
  
  var targetGuids = initHashSet[string]()
  var guidToPaths = initTable[string, AssetPaths]()

  collectTargetAssets(opts.inputDir, targetGuids, guidToPaths)

  if opts.includeDeps:
    resolveDependencies(opts.inputDir, targetGuids, guidToPaths)

  if targetGuids.len == 0:
    echo "No assets found to package."
    return

  preparePackageTempDir(opts.inputDir, tempArchDir, targetGuids, guidToPaths)

  let tarball = Tarball()
  for guid in targetGuids:
    tarball.addDir(tempArchDir / guid)
  tarball.writeTarball(tempTarFile)
  
  let tarData = readFile(tempTarFile)
  let gzData = compress(tarData, BestCompression, dfGzip)
  let finalData = overrideGzipOriginalName(gzData, "archtemp.tar")
  writeFile(opts.outputFile, finalData)

proc main() =
  let opts = parseCliArgs()
  executePackaging(opts)

when isMainModule:
  main()

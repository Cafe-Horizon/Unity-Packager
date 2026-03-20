import std/[os, strutils, times, parseopt, tables, sets]
import zippy/tarballs

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

proc main() =
  var inputDir = ""
  var outputFile = ""
  var includeDeps = false
  
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if inputDir == "": inputDir = key
      elif outputFile == "": outputFile = key
    of cmdLongOption, cmdShortOption:
      if key == "dependencies" or key == "d":
        if val == "" or val.toLowerAscii() == "true":
          includeDeps = true
        elif val.toLowerAscii() == "false":
          includeDeps = false
    of cmdEnd: discard

  if inputDir == "" or outputFile == "":
    echo "Usage: packager [options] <inputDir> <outputFile.unitypackage>"
    echo "Options:"
    echo "  -d, --dependencies[=true|false]  Include dependencies (default: false)"
    quit(1)
    
  inputDir = absolutePath(inputDir)
  outputFile = absolutePath(outputFile)
  
  let tempArchDir = getTempDir() / ("unitypackager_" & $getTime().toUnix())
  let tempTarball = tempArchDir & ".tar.gz"
  defer:
    if fileExists(tempTarball): removeFile(tempTarball)
    if dirExists(tempArchDir): removeDir(tempArchDir)
  createDir(tempArchDir)
  
  var targetGuids = initHashSet[string]()
  var guidToPaths = initTable[string, tuple[meta: string, asset: string]]()

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
            guidToPaths[guid] = (path, assetPath)

  if includeDeps:
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
              guidToPaths[dGuid] = (dAssetPath & ".meta", dAssetPath)
              queue.add(dGuid)

  for guid in targetGuids:
    let paths = guidToPaths[guid]
    let metaPath = paths.meta
    let assetPath = paths.asset
    let isDir = dirExists(assetPath)
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

  if targetGuids.len == 0:
    echo "No assets found to package."
    quit(0)

  let tarball = Tarball()
  for guid in targetGuids:
    tarball.addDir(tempArchDir / guid)
  tarball.writeTarball(tempTarball)
  moveFile(tempTarball, outputFile)

main()

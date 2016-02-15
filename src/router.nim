import strutils, parseutils, strtabs, sequtils
import logging
import critbits
import URI

export URI, strtabs

#
#Type Declarations
#

const pathSeparator = '/'
const allowedCharsInUrl = {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', pathSeparator}
const wildcard = '*'
const startParam = '{'
const endParam = '}'
const specialSectionStartChars = {pathSeparator, wildcard, startParam}
const allowedCharsInPattern = allowedCharsInUrl + {wildcard, startParam, endParam}

type
  HttpVerb* = enum
    GET = "get"
    HEAD = "head"
    OPTIONS = "options"
    PUT = "put"
    POST = "post"
    DELETE = "delete"

  PatternMatchingType = enum
    ptrnWildcard
    ptrnParam
    ptrnText
    ptrnStartHeaderConstraint
    ptrnEndHeaderConstraint

  # Structures for setting up the mappings
  MapperKnot = object
    case kind : PatternMatchingType:
      of ptrnParam, ptrnText:
        value : string
      of ptrnWildcard, ptrnEndHeaderConstraint:
        discard
      of ptrnStartHeaderConstraint:
        headerName : string

  # Structures for holding fully parsed mappings
  PatternNode[H] = ref object
    case kind : PatternMatchingType: # TODO: should be able to extend MapperKnot to get this, compiled wont let me, investigate further
      of ptrnParam, ptrnText:
        value : string
      of ptrnWildcard, ptrnEndHeaderConstraint:
        discard
      of ptrnStartHeaderConstraint:
        headerName : string
    case isLeaf : bool: #a leaf node is one with no children
      of true:
        discard
      of false:
        children : seq[PatternNode[H]]
    case isTerminator : bool: # a terminator is a node that can be considered a mapping on its own, matching could stop at this node or continue. If it is not a terminator, matching can only continue
      of true:
        handler : H
      of false:
        discard

  # Router Structures
  Router*[H] = ref object
    methodRouters : CritBitTree[PatternNode[H]]
    logger : Logger

  RoutingArgs* = object
    pathArgs* : StringTableRef
    queryArgs* : StringTableRef
    bodyArgs* : StringTableRef

  RoutingResultType* = enum
    routingSuccess
    routingFailure
  RoutingResult*[H] = object
    case status* : RoutingResultType:
      of routingSuccess:
        handler* : H
        arguments* : RoutingArgs
      of routingFailure:
        discard

  # Exceptions
  RoutingError* = object of Exception
  MappingError* = object of Exception

#
# Stringification / other operators
#
proc `$`(piece : MapperKnot) : string =
  case piece.kind:
    of ptrnParam, ptrnText:
      result = $(piece.kind) & ":" & piece.value
    of ptrnWildcard, ptrnEndHeaderConstraint:
      result = $(piece.kind)
    of ptrnStartHeaderConstraint:
      result = $(piece.kind) & ":" & piece.headerName
proc `$`[H](node : PatternNode[H]) : string =
  case node.kind:
    of ptrnParam, ptrnText:
      result = $(node.kind) & ":value=" & node.value & ", "
    of ptrnWildcard, ptrnEndHeaderConstraint:
      result = $(node.kind) & ":"
    of ptrnStartHeaderConstraint:
      result = $(node.kind) & ":" & node.headerName & ", "
  result = result & "leaf=" & $node.isLeaf & ", terminator=" & $node.isTerminator
proc `==`[H](node : PatternNode[H], knot : MapperKnot) : bool =
  result = (node.kind == knot.kind)

  if (result):
    case node.kind:
      of ptrnText, ptrnParam:
        result = (node.value == knot.value)
      of ptrnStartHeaderConstraint:
        result = (node.headerName == knot.headerName)
      else:
        discard

#
# Debugging routines
#

proc printRoutingTree[H](node : PatternNode[H], tabs : int = 0) =
  debugEcho ' '.repeat(tabs), $node
  if not node.isLeaf:
    for child in node.children:
      printRoutingTree(child, tabs + 1)

proc printMappings*[H](router : Router[H]) {.gcsafe.} =
  for verb, tree in pairs(router.methodRouters):
    debugEcho verb.toUpper()
    printRoutingTree(tree)

#
# Constructors
#
proc newRouter*[H](logger : Logger = newConsoleLogger()) : Router[H] =
  result = Router[H](methodRouters:CritBitTree[PatternNode[H]](), logger:logger)

#
# Rope procedures. A rope is a chain of tokens representing the url
#

proc ensureCorrectRoute(
  path : string
) : string {.noSideEffect, raises:[MappingError].} =
  if(not path.allCharsInSet(allowedCharsInPattern)):
    raise newException(MappingError, "Illegal characters occurred in the mapped pattern, please restrict to alphanumerics, or the following: - . _ ~ /")

  #if a url ends in a forward slash, we discard it and consider the matcher the same as without it
  let pathLen = path.len
  result = path

  if result[^1] == pathSeparator: #patterns should not end in a separator, it's redundant
    result = result[0..^2]
  if not (result[0] == '/'): #ensure each pattern is relative to root
    result.insert("/")

proc emptyKnotSequence(
  knotSeq : seq[MapperKnot]
) : bool {.noSideEffect.} =
  ##
  ## A knot sequence is empty if it A) contains no elements or B) it contains a single text element with no value
  ##
  result = len(knotSeq) == 0 or (len(knotSeq) == 1 and knotSeq[0].kind == ptrnText and knotSeq[0].value == "")

proc generateRope(
  pattern : string,
  startIndex : int = 0
) : seq[MapperKnot] {.noSideEffect, raises: [MappingError].} =
  ##
  ## Translates the string form of a pattern into a sequence of MapperKnot objects to be parsed against
  ##
  var token : string
  let tokenSize = pattern.parseUntil(token, specialSectionStartChars, startIndex)
  var newStartIndex = startIndex + tokenSize

  if newStartIndex < pattern.len(): # we encountered a wildcard or parameter def, there could be more left
    let specialChar = pattern[newStartIndex]
    newStartIndex += 1

    var scanner : MapperKnot

    if specialChar == wildcard:
      scanner = MapperKnot(kind:ptrnWildcard)
    elif specialChar == startParam:
      var paramName : string
      let paramNameSize = pattern.parseUntil(paramName, endParam, newStartIndex)
      newStartIndex += (paramNameSize + 1)
      scanner = MapperKnot(kind:ptrnParam, value:paramName)
    elif specialChar == pathSeparator:
      scanner = MapperKnot(kind:ptrnText, value:($pathSeparator))
    else:
      raise newException(MappingError, "Unrecognized special character")

    var prefix : seq[MapperKnot]
    if tokenSize > 0:
      prefix = @[MapperKnot(kind:ptrnText, value:token),   scanner]
    else:
      prefix = @[scanner]

    let suffix = generateRope(pattern, newStartIndex)

    if emptyKnotSequence(suffix):
      return prefix
    else:
      return concat(prefix, suffix)

  else: #no more wildcards or parameter defs, the rest is static text
    result = newSeq[MapperKnot](len(token))
    for i, c in pairs(token):
      result[i] = MapperKnot(kind:ptrnText, value:($c))

#
# Node procedures. A pattern node represents part of a chain representing a matchable path
#

proc terminatingPatternNode[H](
  oldNode : PatternNode[H],
  knot : MapperKnot,
  handler : H
) : PatternNode[H] {.noSideEffect, raises: [MappingError].} =
  if oldNode.isTerminator: # Already mapped
    raise newException(MappingError, "Duplicate mapping detected")
  case knot.kind:
    of ptrnText, ptrnParam:
      result = PatternNode[H](kind: knot.kind, value: knot.value, isLeaf: oldNode.isLeaf, isTerminator: true, handler: handler)
    of ptrnWildcard, ptrnEndHeaderConstraint:
      result = PatternNode[H](kind: knot.kind, isLeaf: oldNode.isLeaf, isTerminator: true, handler: handler)
    of ptrnStartHeaderConstraint:
      result = PatternNode[H](kind: knot.kind, headerName: knot.headerName, isLeaf: oldNode.isLeaf, isTerminator: true, handler: handler)

  result.handler = handler

  if not result.isLeaf:
    result.children = oldNode.children

proc parentalPatternNode[H](
  oldNode : PatternNode[H]
) : PatternNode[H] {.noSideEffect.} =
  case oldNode.kind:
    of ptrnText, ptrnParam:
      result = PatternNode[H](kind: oldNode.kind, value: oldNode.value, isLeaf: false, children: newSeq[PatternNode[H]](), isTerminator: oldNode.isTerminator)
    of ptrnWildcard, ptrnEndHeaderConstraint:
      result = PatternNode[H](kind: oldNode.kind, isLeaf: false, children: newSeq[PatternNode[H]](), isTerminator: oldNode.isTerminator)
    of ptrnStartHeaderConstraint:
      result = PatternNode[H](kind: oldNode.kind, headerName: oldNode.headerName, isLeaf: false, children: newSeq[PatternNode[H]](), isTerminator: oldNode.isTerminator)

  if result.isTerminator:
    result.handler = oldNode.handler

proc indexOf[H](nodes : seq[PatternNode[H]], knot : MapperKnot) : int =
  ##
  ## Finds the index of nodes that matches the given knot. If none is found, returns -1
  ##
  for index, child in pairs(nodes):
    if child == knot:
      return index
  return -1 #the 'not found' value

proc chainTree[H](rope : seq[MapperKnot], handler : H) : PatternNode[H] =
  ##
  ## Creates a tree made up of single-child nodes that matches the given rope. The last node in the tree is a terminator with the given handler.
  ##
  let knot = rope[0]
  let lastKnot = (rope.len == 1) #since this is a chain tree, the only leaf node is the terminator node, so they are mutually linked, if this is true then it is both

  case knot.kind:
    of ptrnText, ptrnParam:
      result = PatternNode[H](kind: knot.kind, value: knot.value, isLeaf: lastKnot, isTerminator: lastKnot)
    of ptrnWildcard, ptrnEndHeaderConstraint:
      result = PatternNode[H](kind: knot.kind, isLeaf: lastKnot, isTerminator: lastKnot)
    of ptrnStartHeaderConstraint:
      result = PatternNode[H](kind: knot.kind, headerName: knot.headerName, isLeaf: lastKnot, isTerminator: lastKnot)

  if lastKnot:
    result.handler = handler
  else:
    result.children = @[chainTree(rope[1.. ^1], handler)] #continue the chain

proc merge[H](
  node : PatternNode[H],
  rope : seq[MapperKnot],
  handler : H
) : PatternNode[H] {.noSideEffect, raises: [MappingError].} =
  ##
  ## Merges the given sequence of MapperKnots into the given tree as a new mapping. This does not mutate the given node, instead it will return a new one
  ##
  if rope.len == 1: # Terminating knot reached, finish the merge
    result = terminatingPatternNode(node, rope[0], handler)
  else:
    let currentKnot = rope[0]
    let nextKnot = rope[1]
    let remainder = rope[1.. ^1]

    assert node == currentKnot

    var childIndex = -1
    if node.isLeaf: #node isn't a parent yet, make it one to continue the process
      result = parentalPatternNode(node)
    else:
      result = node
      childIndex = node.children.indexOf(nextKnot)

    if childIndex == -1: # the next knot doesn't map to a child of this node, needs to me directly translated into a deep tree (one branch per level)
      result.children.add(chainTree(remainder, handler)) # make a node containing everything remaining and inject it
    else:
      result.children[childIndex] = merge(result.children[childIndex], remainder, handler)

proc contains[H](
  node : PatternNode[H],
  rope : seq[MapperKnot]
) : bool =
  ##
  ## Determines whether or not merging rope into node will create a mapping conflict
  ##
  let knot = rope[0]

  #are each equivalent?
  if node.kind == knot.kind:
    if node.kind == ptrnText:
      result = (node.value == knot.value)
    elif node.kind == ptrnStartHeaderConstraint:
      result = (node.headerName == knot.headerName)
    else:
      result = true
  else:
    if
      (node.kind == ptrnWildcard and knot.kind == ptrnParam) or
      (node.kind == ptrnParam and knot.kind == ptrnWildcard) or
      (node.kind == ptrnWildcard and knot.kind == ptrnText) or
      (node.kind == ptrnParam and knot.kind == ptrnText) or
      (node.kind == ptrnText and knot.kind == ptrnParam) or
      (node.kind == ptrnText and knot.kind == ptrnWildcard):
      result = true
    else:
      result = false

  #are possible children equivalent?
  if not node.isLeaf and result:
    if node.children.len > 0:
      result = false #false until proven otherwise
      for child in node.children:
        if child.contains(rope[1.. ^1]): #does the child match the rest of the rope?
          result = true
          break
  elif node.isLeaf and rope.len > 1: #the node is a leaf but we want to map further to it, so it won't conflict
    result = false

#
# Mapping procedures
#

proc map*[H](
  router : Router[H],
  handler : H,
  verb: HttpVerb,
  pattern : string,
  headers : StringTableRef = newStringTable()
) {.noSideEffect.} =
  ##
  ## Add a new mapping to the given router instance
  ##
  var rope = generateRope(ensureCorrectRoute(pattern)) # initial rope

  if headers != nil: # extend the rope with any header constraints
    for key, value in headers:
      rope.add(MapperKnot(kind:ptrnStartHeaderConstraint, headerName:key))
      rope = concat(rope, generateRope(value))
      rope.add(MapperKnot(kind:ptrnEndHeaderConstraint))

  var nodeToBeMerged : PatternNode[H]
  if router.methodRouters.hasKey($verb):
    nodeToBeMerged = router.methodRouters[$verb]
    if nodeToBeMerged.contains(rope):
      raise newException(MappingError, "Duplicate mapping encountered: " & pattern)
  else:
    nodeToBeMerged = PatternNode[H](kind:ptrnText, value:($pathSeparator), isLeaf:true, isTerminator:false)

  router.methodRouters[$verb] = nodeToBeMerged.merge(rope, handler)

  router.logger.log(lvlInfo, "Created ", $verb, " mapping for '", pattern, "'")

#
# Data extractors and utilities
#

proc extractEncodedParams(input : string) : StringTableRef {.noSideEffect.} =
  var index = 0
  result = newStringTable()

  while index < input.len():
    var paramValuePair : string
    let pairSize = input.parseUntil(paramValuePair, '&', index)

    index += pairSize + 1

    let equalIndex = paramValuePair.find('=')

    if equalIndex == -1: #no equals, just a boolean "existance" variable
      result[paramValuePair] = "" #just insert a record into the param table to indicate that it exists
    else: #is a 'setter' parameter
      let paramName = paramValuePair.substr(0, equalIndex - 1)
      let paramValue = paramValuePair.substr(equalIndex + 1)
      result[paramName] = paramValue

  return result

const FORM_URL_ENCODED = "application/x-www-form-urlencoded"
const FORM_MULTIPART_DATA = "multipart/form-data"

proc extractFormBody(body : string, contentType : string) : StringTableRef {.noSideEffect.} =
  if contentType.startsWith(FORM_URL_ENCODED):
    return body.extractEncodedParams()
  elif contentType.startsWith(FORM_MULTIPART_DATA):
    assert(false, "Multipart form data not yet supported")
  else:
    return newStringTable()

proc trimPath(path : string) : string {.noSideEffect.} =
  var path = path
  if path != "/": #the root string is special
    path.removeSuffix('/') #trailing slashes are considered redundant
  result = path

#
# Compression routines, compression makes matching more efficient. Once compressed, a router is immutable
#
proc compress[H](node : PatternNode[H]) : PatternNode[H] =
  ##
  ## Finds sequences of single ptrnText nodes and combines them to reduce the depth of the tree
  ##
  if node.isLeaf: #if it's a leaf, there are clearly no descendents, and if it is a terminator then compression will alter the behavior
    return node
  elif node.kind == ptrnText and not node.isTerminator and len(node.children) == 1:
    let compressedChild = compress(node.children[0])
    if compressedChild.kind == ptrnText:
      result = compressedChild
      result.value = node.value & compressedChild.value
      return

  result = node
  result.children = map(result.children, compress)

proc compress*[H](router : Router[H]) =
  ##
  ## Compresses the entire contents of the given router. Successive calls will recompress, but may not be efficient, so use this only when you are done mapping.
  ##
  for index, existing in pairs(router.methodRouters):
    router.methodRouters[index] = compress(existing)

#
# Procedures to match against paths
#

proc matchTree[H](
  head : PatternNode[H],
  path : string,
  headers : StringTableRef,
  pathIndex : int = 0,
  pathArgs : StringTableRef = newStringTable()
) : RoutingResult[H] {.noSideEffect.} =
  ##
  ## Check whether the given path matches the given tree node starting from pathIndex
  ##
  var node = head
  var pathIndex = pathIndex

  block matching:
    while pathIndex >= 0:
      case node.kind:
        of ptrnText:
          if path.continuesWith(node.value, pathIndex):
            pathIndex += node.value.len()
          else:
            break matching
        of ptrnWildcard:
          pathIndex = path.find(pathSeparator, pathIndex) #skip forward to the next separator
          if pathIndex == -1:
            pathIndex = len(path)
        of ptrnParam:
          let newPathIndex = path.find(pathSeparator, pathIndex) #skip forward to the next separator
          if newPathIndex == -1:
            pathArgs[node.value] = path[pathIndex.. ^1]
            pathIndex = len(path)
          else:
            pathArgs[node.value] = path[pathIndex..newPathIndex - 1]
            pathIndex = newPathIndex
        of ptrnStartHeaderConstraint:
          for child in node.children:
            let childResult = child.matchTree(
              path=headers.getOrDefault(node.headerName),
              pathIndex=0,
              headers=headers
            )

            if childResult.status == routingSuccess:
              for key, value in childResult.arguments.pathArgs:
                pathArgs[key] = value
              return RoutingResult[H](
                status:routingSuccess,
                handler:childResult.handler,
                arguments:RoutingArgs(pathArgs:pathArgs)
              )
          return RoutingResult[H](status:routingFailure)
        of ptrnEndHeaderConstraint:
          if node.isTerminator and node.isLeaf:
            return RoutingResult[H](
              status:routingSuccess,
              handler:node.handler,
              arguments:RoutingArgs(pathArgs:pathArgs)
            )

      if pathIndex == len(path) and node.isTerminator: #the path was exhausted and we reached a node that has a handler
        return RoutingResult[H](
          status:routingSuccess,
          handler:node.handler,
          arguments:RoutingArgs(pathArgs:pathArgs)
        )
      elif not node.isLeaf: #there is children remaining, could match against children
        if node.children.len() == 1: #optimization for single child that just points the node forward
          node = node.children[0]
        else: #more than one child
          assert node.children.len() != 0
          for child in node.children:
            result = child.matchTree(path, headers, pathIndex, pathArgs)
            if result.status == routingSuccess:
              return;
          break matching #none of the children matched, assume no match
      else: #its a leaf and we havent' satisfied the path yet, let the last line handle returning
        break matching

  result = RoutingResult[H](status:routingFailure)

proc route*[H](
  router : Router[H],
  requestMethod : string,
  requestUri : URI,
  requestHeaders : StringTableRef = newStringTable(),
  requestBody : string = ""
) : RoutingResult[H] {.noSideEffect.} =
  ##
  ## Find a mapping that matches the given request, and execute it's associated handler
  ##
  let verb = requestMethod.toLower()
  router.logger.log(lvlDebug, "Routing against path => ", requestUri.path)

  if router.methodRouters.hasKey(verb):
    result = matchTree(router.methodRouters[verb], trimPath(requestUri.path), requestHeaders)

    if result.status == routingSuccess:
      result.arguments.queryArgs = extractEncodedParams(requestUri.query)
      result.arguments.bodyArgs = extractFormBody(requestBody, requestHeaders.getOrDefault("Content-Type"))
  else:
    result = RoutingResult[H](status:routingFailure)

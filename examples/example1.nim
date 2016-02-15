import router

import logging
import asynchttpserver, strtabs, times, asyncdispatch, math

type
  RequestHandler* = proc (
    req: Request,
    headers : var StringTableRef,
    args : RoutingArgs
  ) : string {.gcsafe.}

#
# Initialization
#
var logger = newConsoleLogger()
let server = newAsyncHttpServer()
logger.log(lvlInfo, "****** Created server on ", getTime(), " ******")

#
# Set up mappings
#
var mapper = newRouter[RequestHandler](logger)

mapper.map(
  proc (req: Request, headers : var StringTableRef, args : RoutingArgs) : string {.gcsafe.} = return "You visited " & req.url.path
  , GET, "/")

logger.log(lvlInfo, "****** Compressing routing tree ******")
mapper.compress()

#
# Set up the dispatcher
#

# NOTE: these only use unsafe pointers to work with asynchttpserver, which requires full gcsafety in thread mode
let routerPtr = addr mapper
let loggerPtr = addr logger

proc dispatch(req: Request) {.async, gcsafe.} =
  ##
  ## Figures out what handler to call, and calls it
  ##
  let startT = epochTime()
  let matchingResult = routerPtr[].route(req.reqMethod, req.url, req.headers, req.body)
  let endT = epochTime()
  loggerPtr[].log(lvlDebug, "Routing took ", ((endT - startT) * 1000), " millis")

  if matchingResult.status == routingFailure:
    await req.respond(Http404, "Resource not found")
  else:
    var
      statusCode : HttpCode
      headers = newStringTable()
      content : string
    try:
      content = matchingResult.handler(req, headers, matchingResult.arguments)
      statusCode = Http200
    except:
      loggerPtr[].log(lvlError, "Internal error occured:\n\t", getCurrentExceptionMsg())
      content = "Internal server error"
      statusCode = Http500

    await req.respond(statusCode, content, headers)

# start up the server
logger.log(lvlInfo, "****** Started server on ", getTime(), " ******")
waitFor server.serve(Port(8080), dispatch)

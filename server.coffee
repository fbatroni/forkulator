express     = require 'express'
morgan      = require 'morgan'
connect     = require 'connect'
log         = require 'simplog'
path        = require 'path'
fs          = require 'fs'
Promise     = require 'bluebird'
through     = require 'through'
_           = require 'lodash'
child_process = require 'child_process'
body_parser   = require 'body-parser'
util          = require 'util'
stream        = require 'stream'

dieInAFire = (message, errorCode=1) ->
  log.error message
  process.exit errorCode

config=
  outputDirectory: process.env.FORKULATOR_TEMP ||
    process.env.TEMP ||
    process.env.TMPDIR || dieInAFire 'I could not find a place to write my output'
  maxConcurrentRequests: process.env.MAX_CONCURRENCY || 5
  commandPath: process.env.COMMAND_PATH || path.join __dirname, "commands"

app = express()
app.use connect()
# simply parse all bodies as string so we can pass whatever it
# is to the command
app.use body_parser.text(type: () -> true)
app.use morgan('combined')

# used to uniquely identify requests throughout the lifetime of forkulator
requestCounter = 0
# used to count active requests so throttling, if desired, can be done
countOfCurrentlyExecutingRequests = 0

createTempFileName = (prefix) ->
  prefix + process.pid + requestCounter + ""

createTempFilePath = (prefix) ->
  path.join config.outputDirectory, createTempFileName(prefix)

executeThrottled = (req, res) ->
  requestCounter++
  # if we've not disabled throttling ( set to -1 ) then we see that we're running no
  # more than our maximum allowed concurrent requests
  if config.maxConcurrentRequests is -1 || (countOfCurrentlyExecutingRequests < config.maxConcurrentRequests)
    log.debug 'executing request'
    countOfCurrentlyExecutingRequests++
    handleRequest(req,res).then(() -> countOfCurrentlyExecutingRequests--)
  else
    # deny execution of request, tell caller to try again
    log.warn "too busy to handle request"
    res.status(503).send(message: "too busy, try again later").end()

app.use((req, res, next) -> executeThrottled(req, res))

waitForEvent = (resolveEvent, emitter, rejectEvent='error') ->
  new Promise (resolve, reject) ->
    emitter.on resolveEvent, () -> resolve(emitter)
    emitter.on(rejectEvent, reject) if rejectEvent

resolveWithEvent = (context, eventName, emitter, params=null, rejectEvent='error') ->
  new Promise((resolve, reject) ->
    if _.isArray eventName
      console.log "hooking #{eventName}"
      _.each(eventName, (n) ->
        emitter.on(n, () ->
          if params
            resolve(_.extend(context, _.zipObject(params, arguments)))
          else
            resolve.apply(this, arguments)
        )
      )
    else
      emitter.on(eventName, () ->
        if params
          resolve(_.extend(context, _.zipObject(params, arguments)))
        else
          resolve.apply(this, arguments)
      )
    console.log "hooking #{rejectEvent}"
    emitter.on('error', (e) -> reject(e))
  )

promiseToEnd = (stream) ->
  waitForEvent 'end', stream

promiseToClose = (emitter) ->
  waitForEvent 'close', emitter

openForWrite = (path) ->
  waitForEvent 'open', fs.createWriteStream(path)

openForRead = (path) ->
  waitForEvent 'open', fs.createReadStream(path)

writeAndClose = (data, stream) ->
  stream.end data
  waitForEvent 'close', stream

handleRequest = (req,res) ->
  err = null
  commandFilePath = path.join config.commandPath, req.path
  #
  # we're gonna do our best to return json in all cases
  res.type('application/json')

  createStreamTransform = () ->
    through (data) ->
      this.emit 'data', data.toString().replace(/\n/g, "\\n"),
      null,
      autoDestroy: false

  returnWhen = (object, theseComplete) ->
    Promise.props(_.extend(object, theseComplete))

  Promise.resolve(commandFilePath: path.join(config.commandPath, req.path))
  .then (context) -> returnWhen(context,
    requestData:
      url: req.url
      query: if _.isEmpty(req.query) then null else req.query
      body: if _.isEmpty(req.body) then null else req.body
      headers: req.headers
      path: req.path
    )
  .then (context) -> returnWhen(context, stdinfileStream: openForWrite(createTempFilePath 'stdin'))
  .then (context) -> returnWhen(context, stdinWriteStream: writeAndClose(JSON.stringify(context.requestData), context.stdinfileStream))
  .then (c) ->
    whenTheseAreDone =
      stdinfileStream: openForRead(c.stdinWriteStream.path)
      outfileStream: openForWrite(createTempFilePath 'stdout-')
      errfileStream: openForWrite(createTempFilePath 'stderr-')
    returnWhen(c, whenTheseAreDone)
  .then (context) ->
    log.debug 'starting process: %s', context.commandFilePath
    commandProcess = child_process.spawn(context.commandFilePath, [], stdio: ['pipe', context.outfileStream, context.errfileStream])
    console.log util.inspect(commandProcess.stdin)
    commandProcess.on 'error', console.log
    commandProcess.on 'exit', console.log

    #context.stdinfileStream.pipe commandProcess.stdin
    resolveWithEvent(context, ['close', 'exit'], commandProcess, ['exitCode', 'signal'])
  .then (context) ->
      log.debug "command (#{context.commandFilePath}) completed exit code #{context.exitCode}"
      if context.exitCode != 0 || context.signal
        res.status 500
        res.write '{"message":"'
        res.write "killed by signal" + context.signal if context.signal
        errStream = fs.createReadStream context.errfileStream.path
        errStream.on 'error', (e) -> res.write 'error reading stderr from the command ' + e + '\\n'
        outStream = fs.createReadStream context.outfileStream.path
        outStream.on 'error', (e) -> res.write 'error reading stdout from the command ' + e + '\\n'
        errStream.pipe(createStreamTransform()).pipe(res, end: false)
        outStream.pipe(createStreamTransform()).pipe(res, end: false)
        promiseToEnd(errStream)
          .then(promiseToEnd(outStream))
          .then( -> res.write('"}'))
      else
        fs.createReadStream(context.outfileStream.path).pipe(res)
      # when our response is finished (we've sent all we will send)
      # we clean up after ourselves
      new Promise (resolve, reject) ->
        res.on 'finish', () -> resolve([context.stdinfileStream.path, context.errfileStream.path, context.outfileStream.path])
  .spread (stdinfilePath, errfilePath, outfilePath) ->
    # I really want to pack all these up and keep 'em for reference
    #fs.unlink(stdinfilePath, (e) -> log.warn(e) if e)
    #fs.unlink(outfilePath, (e) -> log.warn(e) if e)
    #fs.unlink(errfilePath, (e) -> log.warn(e) if e)
    console.log "done"
  .catch (e) ->
    log.error "something awful happened #{e}\n#{e.stack}"
    res.write "something awful happend: " + e
  .error (e) ->
    log.error "something awful happened #{e}\n#{e.stack}"
    res.write "something awful happend: " + e
  .finally () -> res.end()
    
listenPort = process.env.PORT || 3000
log.info "starting app " + process.env.APP_NAME
log.info "listening on " + listenPort
log.debug "debug logging enabled"
log.debug config
app.listen listenPort

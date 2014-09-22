rawBody = require 'raw-body'
When = require 'when'
path = require 'path'
fs = require 'fs'

# It should work for any version of when.js
nodefn = try
  require 'when/node'
catch
  require 'when/node/function'

{Buffer} = require 'buffer'
{Stream, PassThrough} = require 'stream'

streamToBuffer = nodefn.lift rawBody
PassThrough ||= require 'through'

tmpFilename = (ext = 'tmp') ->
  tmpDir = process.env.TMPDIR || '/tmp'
  base = Math.random().toString(36).slice(2,12)
  path.resolve tmpDir, "node-webp-#{base}.#{ext}"

bindCallback = (promise, next) ->
  if typeof next is 'function'
    nodefn.bindCallback promise, next
  else
    promise

module.exports =
  _createFileSource: ->
    return @_tmpFilename if @_tmpFilename
    filename = tmpFilename()
    done = if Buffer.isBuffer @source
      nodefn.call fs.writeFile, filename, @source
    else if @source instanceof Stream
      {resolve, reject, promise} = When.defer()
      deferred = When.defer()
      stream = fs.createWriteStream(filename)
        .once('error', reject)
        .once('close', resolve)
        .once('finish', resolve)
      @source.pipe stream
      promise.ensure ->
        # Cleanup
        stream.removeListener 'error', reject
        stream.removeListener 'close', resolve
        stream.removeListener 'finish', resolve
    else
      When.reject new Error 'Mailformed source'
    @_tmpFilename = done.then -> filename

  _cleanup: (varname) ->
    return unless varname and promise = @[varname]
    delete @[varname]
    When(promise).then (filename) ->
      nodefn.call fs.unlink, filename if filename
    .otherwise ->

  _fileSource: ->
    if typeof @source is 'string'
      @source
    else
      @_createFileSource()

  _write: (source, outname) ->
    outname ||= '-'
    stdin = (typeof source isnt 'string')
    stdout = outname is '-'
    args = [].concat @args(), [
      '-o', outname
      '--', (if stdin then '-' else source)
    ]
    unless stdin
      @_spawn args, stdin, stdout
    else if Buffer.isBuffer source
      res = @_spawn args, stdin, stdout
      res.stdin.end source
      res
    else if source instanceof Stream
      res = @_spawn args, stdin, stdout
      source.pipe res.stdin
      res
    else
      promise: When.reject new Error 'Mailformed source'

  write: (outname, next) ->
    promise = unless outname
      When.reject new Error 'outname in not specified'
    else if @_stdin
      (@_write @source, outname).promise
    else
      When(@_fileSource()).then (filename) =>
        (@_write filename, outname).promise
      .ensure =>
        @_cleanup '_tmpFilename'
    bindCallback promise, next

  toBuffer: (next) ->
    bindCallback (streamToBuffer @stream()), next

  _stream: (source, outstream) ->
    res = @_write source, '-'
    if (piped = res.stdout?)
      res.stdout.pipe outstream, end: false
    res.promise.then ->
      unless piped
        throw new Error 'Failed to pipe stdout'
      outstream.end()
    .otherwise (err) ->
      outstream.emit 'error', err

  stream: ->
    res = new PassThrough()
    if @_stdin
      @_stream @source, res
    else
      res.once 'end', =>
        @_cleanup '_tmpFilename'
      res.once 'error', =>
        @_cleanup '_tmpFilename'
      When(@_fileSource()).then (filename) =>
        @_stream filename, res
      .otherwise (err) ->
        res.emit 'error', err
    res

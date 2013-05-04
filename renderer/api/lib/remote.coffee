ipc = require 'ipc'
v8_util = process.atomBinding 'v8_util'

nextCallbackId = 0
storedCallbacks = {}

storeCallback = (callback) ->
  ++nextCallbackId
  storedCallbacks[nextCallbackId] = callback
  nextCallbackId

makeCallback = (id, args) ->
  storedCallbacks[id].apply global, args

releaseCallback = (id) ->
  delete storedCallbacks[id]

# Transform the arguments passed to browser into list of descriptions.
#
# This function assumes an array is passed, and it only converts remote objects
# and functions, other types of values are passed as it is.
wrapArgs = (args) ->
  Array::slice.call(args).map (value) ->
    if typeof value is 'object' and v8_util.getHiddenValue value, 'isRemoteObject'
      type: 'remoteObject', id: value.id
    else if typeof value is 'function'
      type: 'function', id: storeCallback(value)
    else
      type: 'value', value: value

# Transform the description of value into a value or delegate object.
metaToValue = (meta) ->
  switch meta.type
    when 'error' then throw new Error(meta.value)
    when 'value' then meta.value
    when 'array' then (metaToValue(el) for el in meta.members)
    else
      if meta.type is 'function'
        # A shadow class to represent the remote function object.
        ret =
        class RemoteFunction
          constructor: ->
            if @constructor == RemoteFunction
              # Constructor call.
              obj = ipc.sendChannelSync 'ATOM_BROWSER_CONSTRUCTOR', meta.id, wrapArgs(arguments)

              # Returning object in constructor will replace constructed object
              # with the returned object.
              # http://stackoverflow.com/questions/1978049/what-values-can-a-constructor-return-to-avoid-returning-this
              return metaToValue obj
            else
              # Function call.
              ret = ipc.sendChannelSync 'ATOM_BROWSER_FUNCTION_CALL', meta.id, wrapArgs(arguments)
              return metaToValue ret
      else
        ret = v8_util.createObjectWithName meta.name

      # Polulate delegate members.
      for member in meta.members
        do (member) ->
          if member.type is 'function'
            ret[member.name] = ->
              # Call member function.
              ret = ipc.sendChannelSync 'ATOM_BROWSER_MEMBER_CALL', meta.id, member.name, wrapArgs(arguments)
              metaToValue ret
          else
            ret.__defineSetter__ member.name, (value) ->
              # Set member data.
              ipc.sendChannelSync 'ATOM_BROWSER_MEMBER_SET', meta.id, member.name, value

            ret.__defineGetter__ member.name, ->
              # Get member data.
              ret = ipc.sendChannelSync 'ATOM_BROWSER_MEMBER_GET', meta.id, member.name
              metaToValue ret

      # Track delegate object's life time, and tell the browser to clean up
      # when the object is GCed.
      v8_util.setDestructor ret, ->
        ipc.sendChannel 'ATOM_BROWSER_DEREFERENCE', meta.storeId

      # Mark this is a remote object.
      v8_util.setHiddenValue ret, 'isRemoteObject', true

      ret

ipc.on 'ATOM_RENDERER_CALLBACK', (id, args) ->
  makeCallback id, metaToValue(args)

ipc.on 'ATOM_RENDERER_RELEASE_CALLBACK', (id) ->
  releaseCallback id

# Release all resources of current render view when it's going to be unloaded.
window.addEventListener 'unload', (event) ->
  ipc.sendChannelSync 'ATOM_BROWSER_RELEASE_RENDER_VIEW'

# Get remote module.
exports.require = (module) ->
  meta = ipc.sendChannelSync 'ATOM_BROWSER_REQUIRE', module
  metaToValue meta

# Get object with specified id.
exports.getObject = (id) ->
  meta = ipc.sendChannelSync 'ATOM_BROWSER_REFERENCE', id
  metaToValue meta

# Get current window object.
windowCache = null
exports.getCurrentWindow = ->
  return windowCache if windowCache?
  meta = ipc.sendChannelSync 'ATOM_BROWSER_CURRENT_WINDOW'
  windowCache = metaToValue meta

# Get a global object in browser.
exports.getGlobal = (name) ->
  meta = ipc.sendChannelSync 'ATOM_BROWSER_GLOBAL', name
  metaToValue meta

# Get the process object in browser.
processCache = null
exports.__defineGetter__ 'process', ->
  processCache = exports.getGlobal('process') unless processCache?
  processCache

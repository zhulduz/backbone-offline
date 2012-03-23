#    Backbone.offline allows your Backbone.js app to work offline
#    https://github.com/Ask11/bacbone.offline
#
#    (c) 2012 - Aleksey Kulikov
#    May be freely distributed according to MIT license.

window.Offline =
  VERSION: '0.1.1'

  # This is a method for CRUD operations with localStorage.
  # Delegates to 'Offline.Storage' and works as ‘Backbone.sync’ alternative
  localSync: (method, model, options, store) ->
    resp = switch(method)
      when 'read'
        if _.isUndefined(model.id) then store.findAll() else store.find(model)
      when 'create' then store.create(model, options)
      when 'update' then store.update(model, options)
      when 'delete' then store.destroy(model, options)

    if resp then options.success(resp) else options.error('Record not found')

  # Overrides default 'Backbone.sync'. It checks 'storage' property of the model or collection
  # and then delegates to 'Offline.localSync' when property exists else calls the default 'Backbone.sync' with received params.
  sync: (method, model, options) ->
    store = model.storage || model.collection?.storage
    if store
      Offline.localSync(method, model, options, store)
    else
      Backbone.ajaxSync(method, model, options)

# Override 'Backbone.sync' to default to 'Offline.sync'
# the original 'Backbone.sync' is available in 'Backbone.ajaxSync'
Backbone.ajaxSync = Backbone.sync
Backbone.sync = Offline.sync

# This class is use as a wrapper for manipulations with localStorage
# It's based on a great library https://github.com/jeromegn/Backbone.localStorage
# with some specific methods.
#
# Create your collection of this type:
#
# class Dreams extends Backbone.Collection
#   initialize: ->
#     @storage = new Offline.Storage('dreams', this)
#
# After that your collection will work offline.
#
# Instance attributes:
# @name - storage name
# @sync - instance of Offline.Sync
# @allIds - index of ids for the collection
# @destroyIds - index for destroyed models
class Offline.Storage

  # Name of storage and collection link are required params
  constructor: (@name, collection, options = {}) ->
    @allIds = new Offline.Index(@name)
    @destroyIds = new Offline.Index("#{@name}-destroy")
    @sync = new Offline.Sync(collection, this)
    @keys = options.keys || {}

  # Add a model, giving it a unique GUID. Server id saving to "sid".
  # Set a sync's attributes updated_at, dirty and add
  create: (model, options = {}) ->
    model = model.attributes if model.attributes
    model.sid = model.sid || model.id || 'new'
    model.id = this.guid()

    unless options.local
      model.updated_at = (new Date()).toJSON()
      model.dirty = true

    this.save(model)

  # Update a model into the set. Set a sync's attributes update_at and dirty.
  update: (model, options = {}) ->
    unless options.local
      model.set updated_at: (new Date()).toJSON(), dirty: true

    this.save(model)

  # Delete a model from the storage
  destroy: (model, options = {}) ->
    unless options.local or (sid = model.get('sid')) is 'new'
      @destroyIds.add(sid)

    this.remove(model)

  find: (model) ->
    JSON.parse localStorage.getItem("#{@name}-#{model.id}")

  # Returns the array of all models currently in the storage.
  # And refreshes the storage into background
  findAll: ->
    if this.isEmpty() then @sync.full() else @sync.incremental()
    JSON.parse(localStorage.getItem("#{@name}-#{id}")) for id in @allIds.values

  s4: ->
    (((1 + Math.random()) * 0x10000) | 0).toString(16).substring(1)

  guid: ->
    this.s4() + this.s4() + '-' + this.s4() + '-' + this.s4() + '-' + this.s4() + '-' + this.s4() + this.s4() + this.s4()

  save: (item) ->
    this.replaceKeyFields(item, 'local')
    localStorage.setItem "#{@name}-#{item.id}", JSON.stringify(item)
    @allIds.add(item.id)

    return item

  remove: (item) ->
    localStorage.removeItem "#{@name}-#{item.id}"
    @allIds.remove(item.id)

    return item

  isEmpty: ->
    localStorage.getItem(@name) is null

  # Clears the current storage
  clear: ->
    keys = Object.keys(localStorage)
    collectionKeys = _.filter keys, (key) => (new RegExp @name).test(key)
    localStorage.removeItem(key) for key in collectionKeys
    localStorage.setItem(@name, '')
    record.reset() for record in [@allIds, @destroyIds]

  # Replaces local-keys to server-keys based on options.keys.
  replaceKeyFields: (item, method) ->
    item = item.attributes if item.attributes

    for field, collection of @keys
      replacedField = item[field]
      if !/^\w{8}-\w{4}-\w{4}/.test(replacedField) or method isnt 'local'
        newValue = if method is 'local'
          wrapper = new Offline.Collection(collection)
          wrapper.get(replacedField)?.id
        else
          collection.get(replacedField)?.get('sid')
        item[field] = newValue unless _.isUndefined(newValue)
    return item

# Sync collection with a server. All server requests delegated to 'Backbone.sync'
# It provides a backward-compability. If your application is working with 'Backbone.sync'
# it'll be working with a 'Offline.sync'
#
# @storage = new Offline.Storage('dreams', this)
# @storage.sync - access to class instance through Offline.Storage
class Offline.Sync
  constructor: (collection, storage) ->
    @collection = new Offline.Collection(collection)
    @storage = storage

  # @storage.sync.full() - full storage synchronization
  # 1. clear collection and store
  # 2. load new data
  full: (options = {}) ->
    Backbone.ajaxSync 'read', @collection.items, success: (response, status, xhr) =>
      @storage.clear()
      @storage.create(item, local: true) for item in response
      @collection.items.reset(response)
      options.success(response) if options.success

  # @storage.sync.incremental() - incremental storage synchronization
  # 1. pull() - request data from server
  # 2. push() - send modified data to server
  incremental: ->
    this.pull success: => this.push()

  # Requests data from the server and merges it with a collection.
  # It's useful when you want to refresh your collection and don't want to reload it completely.
  # If response does not include any local ids they will be removed
  # Local data will be compared with a server's response using updated_at field and new objects will be created
  #
  # @storage.sync.pull()
  pull: (options = {}) ->
    Backbone.ajaxSync 'read', @collection.items, success: (response, status, xhr) =>
      @collection.destroyDiff(response)
      this.pullItem(item) for item in response
      options.success() if options.success

  pullItem: (item) ->
    local = @collection.get(item.id)
    if local
      this.updateItem(item, local)
    else
      this.createItem(item)

  createItem: (item) ->
    unless _.include(@storage.destroyIds.values, item.id.toString())
      item.sid = item.id
      delete item.id
      @collection.items.create(item, local: true)
      @collection.items.trigger('added')

  updateItem: (item, model) ->
    if (new Date(model.get 'updated_at')) < (new Date(item.updated_at))
      delete item.id
      model.save item, local: true
      model.trigger('updated')

  # Use to send modifyed data to the server
  # You can use it manually for sending changes
  #
  # @storage.sync.push()
  #
  # At first, method gets all dirty-objects (added or updated)
  # and sends every object to server using 'Backbone.sync' method
  # after that it sends deleted objects to the server
  push: ->
    this.pushItem(item) for item in @collection.dirty()
    this.destroyBySid(sid) for sid in @storage.destroyIds.values

  pushItem: (item) ->
    @storage.replaceKeyFields(item, 'server')
    localId = item.id
    delete item.attributes.id
    [method, item.id] = if item.get('sid') is 'new' then ['create', null] else ['update', item.attributes.sid]

    Backbone.ajaxSync method, item, success: (response, status, xhr) =>
      item.set(sid: response.id) if method is 'create'
      item.save {dirty: false}, {local: true}

    item.attributes.id = localId; item.id = localId

  destroyBySid: (sid) ->
    model = @collection.fakeModel(sid)
    Backbone.ajaxSync 'delete', model, success: (response, status, xhr) =>
      @storage.destroyIds.remove(sid)

# Manage indexes storing to localStorage.
# For example 1,2,3,4,5,6
class Offline.Index

  # @name - index name
  # localStorage.setItem 'dreams', '1,2,3,4'
  # records = new Offline.Index('dreams')
  # records.values - an array based on localStorage data
  # => ['1', '2', '3', '4']
  constructor: (@name) ->
    store = localStorage.getItem(@name)
    @values = (store && store.split(',')) || []

  # Add a new item to the end of list
  # records.add '5'
  # records.values
  # => ['1', '2', '3', '4', '5']
  add: (itemId) ->
    unless _.include(@values, itemId.toString())
      @values.push itemId.toString()
    this.save()

  # Remove element from a list of values
  # records.remove '3'
  # records.values
  # => ['1', '2', '4', '5']
  remove: (itemId) ->
    @values = _.without @values, itemId.toString()
    this.save()

  save: -> localStorage.setItem @name, @values.join(',')
  reset: -> @values = []; this.save()

# Use as wrapper for 'Backbone.Collection'
class Offline.Collection

  # @items is an instance of 'Backbone.Collection'
  constructor: (@items) ->

  # Returns models marked as "dirty" - {dirty: true}
  # That is needy for synchronization with server
  dirty: ->
    @items.filter (item) -> item.get('dirty')

  # Get a model from the set by sid.
  get: (sid) ->
    @items.find (item) -> item.get('sid') is sid
 old models from the collection which have not marked as "new"
  destroyDiff: (response) ->
    diff = _.difference(_.without(@items.pluck('sid'), 'new'), _.pluck(response, 'id'))
    this.get(sid)?.destroy(local: true) for sid in diff

  # Use to create a fake model for the set
  fakeModel: (sid) ->
    model = new Backbone.Model()
    model.id = sid
    model.urlRoot = @items.url

    return model
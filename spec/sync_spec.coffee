describe 'Offline.Sync', ->
  beforeEach ->
    localStorage.setItem('dreams', '')
    @dreams = new Dreams()
    @storage = @dreams.storage
    @sync = @storage.sync

  afterEach ->
    localStorage.clear()

  describe 'full', ->
    beforeEach ->
      @options = success: (resp) ->
      @response = [{name: 'Dream 1'}, {name: 'Dream 2'}, {name: 'Dream 3'}]
      registerFakeAjax url: '/api/dreams', successData: @response

    it 'should clear storage', ->
      spyOn(@storage, 'clear')
      @sync.full(@options)
      expect(@storage.clear).toHaveBeenCalled()

    it 'should reset collection', ->
      spyOn(@sync.collection.items, 'reset')
      @sync.full(@options)
      expect(@sync.collection.items.reset).toHaveBeenCalledWith(@response)

    it 'should request data from server', ->
      spyOn($, 'ajax')
      @sync.full(@options)
      expect($.ajax).toHaveBeenCalledWith type: 'GET', dataType: 'json', url: '/api/dreams', success: jasmine.any(Function)

    it 'should store received data to localStorage', ->
      @sync.full(@options)
      localStorage.removeItem('dreams')
      localStorage.removeItem('dreams-destroy')
      expect(localStorage.length).toEqual(3)

    it 'does not mark loaded data as dirty', ->
      @sync.full(@options)
      dirties = @dreams.filter (dream) -> dream.get('dirty')
      expect(dirties.length).toEqual(0)

    it 'should call "options.success" with received data', ->
      callback = jasmine.createSpy('-Success Callback-')
      @options = success: (resp) -> callback(resp)
      @sync.full(@options)
      expect(callback).toHaveBeenCalledWith(@response)

  describe 'incremental', ->
    it 'should call "pull"', ->
      spyOn(@sync, 'pull')
      @sync.incremental()
      expect(@sync.pull).toHaveBeenCalledWith(success: jasmine.any(Function))

    it 'should call "push"', ->
      registerFakeAjax url: '/api/dreams', successData: {}
      spyOn(@sync, 'push')
      @sync.incremental()
      expect(@sync.push).toHaveBeenCalledWith()

  describe 'pull', ->
    beforeEach ->
      @dreams.create(name: 'item 1', sid: '1')
      @dreams.create(name: 'item 2', sid: '2')

      @response = [{name: 'updated item 2', id: '2'}, {name: 'item 3', id: '3'}]
      registerFakeAjax url: '/api/dreams', successData: @response

    it 'should request data from server', ->
      spyOn($, 'ajax')
      @sync.pull()
      expect($.ajax).toHaveBeenCalledWith type: 'GET', dataType: 'json', url: '/api/dreams', success: jasmine.any(Function)

    it 'should destroy old items', ->
      spyOn(@sync.collection, 'destroyDiff')
      @sync.pull()
      expect(@sync.collection.destroyDiff).toHaveBeenCalledWith(@response)

    it 'should call "pullItem" for changed items', ->
      spyOn(@sync, 'pullItem')
      @sync.pull()
      expect(@sync.pullItem.callCount).toBe(2)

  describe 'pullItem', ->
    beforeEach ->
      @dream = @dreams.create({name: 'simple item', updated_at: '2012-03-04T14:00:10Z', sid: '1'}, {local: true})

    it "should update local's item by sid", ->
      @sync.pullItem(id: '1', name: 'updated', updated_at: '2012-03-05T14:00:10Z')
      expect(@dream.get 'name').toEqual('updated')

    it "should create new item when local's item does not find", ->
      @sync.pullItem(id: '2', name: 'create item')
      expect(@sync.collection.get('2').get 'name').toEqual('create item')

  describe 'createItem', ->
    beforeEach ->
      @item = name: 'New', id: '1'
      @collection = @dreams.storage.sync.collection

    it 'should create new item to collection', ->
      spyOn(@dreams, 'create')
      @sync.createItem(@item)
      expect(@dreams.create).toHaveBeenCalledWith {name: 'New', sid: '1'}, {local: true}

    it 'should save item.id to item.sid', ->
      @sync.createItem(@item)
      expect(@collection.get '1').toBeDefined()

    it 'does not mark new item as dirty', ->
      @sync.createItem(@item)
      expect(@collection.get('1').get 'dirty').toBeFalsy()

    it 'does not create item which was deleted local', ->
      @storage.destroyIds.values = ['1']
      @sync.createItem(@item)
      expect(@collection.get '1').toBeUndefined()

  describe 'updateItem', ->
    beforeEach ->
      @dream = @dreams.create({updated_at: '2012-03-04T14:00:10Z', sid: '2'}, {local: true})
      @item = name: 'Updated name', updated_at: '2012-03-04T14:31:40Z', id: '2'

    it 'should update attributes when local updated_at < new updated_at', ->
      @sync.updateItem(@item, @dream)
      expect(@dream.get 'name').toEqual('Updated name')

    it 'does not save id', ->
      @sync.updateItem(@item, @dream)
      expect(@dream.get 'id').toNotEqual('1')

    it 'does nothing when local updated_at greater than new updated_at', ->
      callback = jasmine.createSpy('-Change Callback-')
      @dream.on('change', callback)
      @item.updated_at = '2012-03-04T12:10:10Z'
      @sync.updateItem(@item, @dream)
      expect(callback.callCount).toBe(0)

    it 'does not mark item as dirty', ->
      @sync.updateItem(@item, @dream)
      expect(@dream.get 'dirty').toBeFalsy()

  describe 'push', ->
    it 'should call "pushItem" for dirty items', ->
      @dreams.create()
      @dreams.create(id: '2', name: 'Diving with scuba')
      spyOn(@sync, 'pushItem')

      @sync.push()
      expect(@sync.pushItem.callCount).toBe(2)

    it 'should call "destroyBySid" for destroyed items', ->
      destroyedDream = @dreams.create({id: '3', name: 'Learning to play on sax', sid: '3'}, {local: true})
      destroyedDream.destroy()
      spyOn(@sync, 'destroyBySid')

      @sync.push()
      expect(@sync.destroyBySid.callCount).toBe(1)

  describe 'pushItem', ->
    describe 'when item is new', ->
      beforeEach ->
        @dream = @dreams.create()

      it 'should call Backbone.ajaxSync', ->
        spyOn(Backbone, 'ajaxSync')
        @sync.pushItem(@dream)
        expect(Backbone.ajaxSync).toHaveBeenCalledWith('create', jasmine.any(Object), {success: jasmine.any(Function)})

      it 'sets dirty to false and sets sid', ->
        registerFakeAjax url: '/api/dreams', type: 'post', successData: {id: '12'}
        localId = @dream.id
        @sync.pushItem(@dream)

        expect(@dream.get 'dirty').toBeFalsy()
        expect(@dream.get 'sid').toEqual('12')
        expect(@dream.id).toEqual(localId)

      it 'should call "replaceKeyFields"', ->
        spyOn(@storage, 'replaceKeyFields')
        spyOn(Backbone, 'ajaxSync')
        @sync.pushItem(@dream)
        expect(@storage.replaceKeyFields).toHaveBeenCalledWith(@dream, 'server')

    describe 'when item exists', ->
      beforeEach ->
        @dream = @dreams.create(sid: '101')

      it 'should call Backbone.ajaxSync', ->
        spyOn(Backbone, 'ajaxSync')
        @sync.pushItem(@dream)

        expect(Backbone.ajaxSync).toHaveBeenCalledWith('update', jasmine.any(Object), {success: jasmine.any(Function)})

      it 'sets dirty to false', ->
        registerFakeAjax url: "/api/dreams/101", type: 'put', successData: {}
        localId = @dream.id
        @sync.pushItem(@dream)

        expect(@dream.get 'dirty').toBeFalsy()
        expect(@dream.id).toEqual(localId)

  describe 'destroyBySid', ->
    beforeEach ->
      @sid = @dreams.create(sid: '3', local: true).get('sid')

    it 'should call Backbone.ajaxSync', ->
      spyOn(Backbone, 'ajaxSync')
      @sync.destroyBySid(@sid)
      expect(Backbone.ajaxSync).toHaveBeenCalledWith('delete', jasmine.any(Object), {success: jasmine.any(Function)})

    it 'should clear @destroyIds', ->
      registerFakeAjax url: "/api/dreams/#{@sid}", type: 'delete', successData: {}
      @sync.destroyBySid(@sid)
      expect(@storage.destroyIds.values).toEqual([])
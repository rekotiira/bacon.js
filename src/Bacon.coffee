(this.jQuery || this.Zepto)?.fn.asEventStream = (eventName) ->
  element = this
  new EventStream (sink) ->
    handler = (event) ->
      reply = sink (next event)
      if (reply == Bacon.noMore)
        unbind()
    unbind = -> element.unbind(eventName, handler)
    element.bind(eventName, handler)
    unbind

Bacon = @Bacon = {
  taste : "delicious"
}

Bacon.noMore = "veggies"

Bacon.more = "moar bacon!"

Bacon.never = => new EventStream (sink) =>
  => nop

Bacon.later = (delay, value) ->
  Bacon.sequentially(delay, [value])

Bacon.sequentially = (delay, values) ->
  Bacon.repeatedly(delay, values).take(filter(((e) -> e.hasValue()), map(toEvent, values)).length)

Bacon.repeatedly = (delay, values) ->
  index = -1
  poll = ->
    index++
    toEvent values[index % values.length]
  Bacon.fromPoll(delay, poll)

Bacon.fromPoll = (delay, poll) ->
  new EventStream (sink) ->
    id = undefined
    handler = ->
      value = poll()
      reply = sink value
      if (reply == Bacon.noMore or value.isEnd())
        unbind()
    unbind = -> 
      clearInterval id
    id = setInterval(handler, delay)
    unbind

Bacon.interval = (delay, value) ->
  value = {} unless value?
  poll = -> next(value)
  Bacon.fromPoll(delay, poll)

Bacon.constant = (value) ->
  new Property (sink) ->
    sink(initial(value))
    sink(end())
    nop

Bacon.combineAll = (streams, f) ->
  assertArray streams
  stream = head streams
  for next in (tail streams)
    stream = f(stream, next)
  stream

Bacon.mergeAll = (streams) ->
  Bacon.combineAll(streams, (s1, s2) -> s1.merge(s2))

Bacon.combineAsArray = (streams) ->
  toArray = (x) -> if x? then (if (x instanceof Array) then x else [x]) else []
  concatArrays = (a1, a2) -> toArray(a1).concat(toArray(a2))
  Bacon.combineAll(streams, (s1, s2) ->
    s1.toProperty().combine(s2, concatArrays))

Bacon.latestValue = (src) ->
  latest = undefined
  src.subscribe (event) ->
    latest = event.value if event.hasValue()
  => latest

class Event
  isEvent: -> true
  isEnd: -> false
  isInitial: -> false
  isNext: -> false
  isError: -> false
  hasValue: -> false
  filter: (f) -> true

class Next extends Event
  constructor: (@value) ->
  isNext: -> true
  hasValue: -> true
  fmap: (f) -> next(f(this.value))
  apply: (value) -> next(value)
  filter: (f) -> f(@value)

class Initial extends Next
  isInitial: -> true
  isNext: -> false
  fmap: (f) -> initial(f(this.value))
  apply: (value) -> initial(value)

class End extends Event
  isEnd: -> true
  fmap: -> this
  apply: -> this

class Error extends Event
  constructor: (@error) ->
  isError: -> true
  fmap: -> this
  apply: -> this

class Observable
  onValue: (f) -> @subscribe (event) ->
    f event.value if event.hasValue()
  onError: (f) -> @subscribe (event) ->
    f event.error if event.isError()
  errors: -> @filter(-> false)

class EventStream extends Observable
  constructor: (subscribe) ->
    assertFunction subscribe
    dispatcher = new Dispatcher(subscribe)
    @subscribe = dispatcher.subscribe
    @hasSubscribers = dispatcher.hasSubscribers
  endOnError: ->
    @withHandler (event) ->
      if event.isError()
        @push event
        @push end()
      else
        @push event
  filter: (f) ->
    @withHandler (event) -> 
      if event.filter(f)
        @push event
      else
        Bacon.more
  takeWhile: (f) ->
    @withHandler (event) -> 
      if event.filter(f)
        @push event
      else
        @push end()
        Bacon.noMore
  take: (count) ->
    assert "take: count must >= 1", (count>=1)
    @withHandler (event) ->
      if !event.hasValue()
        @push event
      else if (count == 1)
        @push event
        @push end()
        Bacon.noMore
      else
        count--
        @push event
  skip : (count) ->
    assert "skip: count must >= 0", (count>=0)
    @withHandler (event) ->
      if !event.hasValue()
        @push event
      else if (count > 0)
        count--
        Bacon.more
      else
        @push event

  map: (f) ->
    @withHandler (event) -> 
      @push event.fmap(f)
  flatMap: (f) ->
    root = this
    new EventStream (sink) ->
      children = []
      rootEnd = false
      unsubRoot = ->
      unbind = ->
        unsubRoot()
        for unsubChild in children
          unsubChild()
        children = []
      checkEnd = ->
        if rootEnd and (children.length == 0)
          sink end()
      spawner = (event) ->
        if event.isEnd()
          rootEnd = true
          checkEnd()
        else if event.isError()
          sink event
        else
          child = f event.value
          unsubChild = undefined
          removeChild = ->
            remove(unsubChild, children) if unsubChild?
            checkEnd()
          handler = (event) ->
            if event.isEnd()
              removeChild()
              Bacon.noMore
            else
              reply = sink event
              if reply == Bacon.noMore
                unbind()
              reply
          unsubChild = child.subscribe handler
          children.push unsubChild
      unsubRoot = root.subscribe(spawner)
      unbind
  switch: (f) =>
    @flatMap (value) =>
      f(value).takeUntil(this)
  delay: (delay) ->
    @flatMap (value) ->
      Bacon.later delay, value
  throttle: (delay) ->
    @switch (value) ->
      Bacon.later delay, value
  bufferWithTime: (delay) ->
    values = []
    storeAndMaybeTrigger = (value) ->
      values.push value
      values.length == 1
    flush = ->
      output = values
      values = []
      output
    buffer = ->
      Bacon.later(delay).map(flush)
    @filter(storeAndMaybeTrigger).flatMap(buffer)
  bufferWithCount: (count) ->
    values = []
    @withHandler (event) ->
      flush = =>
        @push next(values)
        values = []
      if event.isError()
        @push event
      else if event.isEnd()
        flush()
        @push event
      else
        values.push(event.value)
        flush() if values.length == count
  merge: (right) -> 
    left = this
    new EventStream (sink) ->
      unsubLeft = nop
      unsubRight = nop
      unsubscribed = false
      unsubBoth = -> unsubLeft() ; unsubRight() ; unsubscribed = true
      ends = 0
      smartSink = (event) ->
        if event.isEnd()
          ends++
          if ends == 2
            sink end()
          else
            Bacon.more
        else
          reply = sink event
          unsubBoth() if reply == Bacon.noMore
          reply
      unsubLeft = left.subscribe(smartSink)
      unsubRight = right.subscribe(smartSink) unless unsubscribed
      unsubBoth

  takeUntil: (stopper) =>
    new EventStream(takeUntilSubscribe(this, stopper))

  toProperty: (initValue) ->
   @scan(initValue, latter)

  scan: (seed, f) -> 
    acc = seed
    handleEvent = (event) -> 
      acc = f(acc, event.value) if event.hasValue()
      @push event.apply(acc)
    d = new Dispatcher(@subscribe, handleEvent)
    subscribe = (sink) ->
      reply = sink initial(acc) if acc?
      d.subscribe(sink) unless reply == Bacon.noMore
    new Property(subscribe)

  distinctUntilChanged: ->
    @withStateMachine undefined, (prev, event) ->
      if !event.hasValue()
        [prev, [event]]
      else if prev isnt event.value
        [event.value, [event]]
      else
        [prev, []]

  withStateMachine: (initState, f) ->
    state = initState
    @withHandler (event) ->
      fromF = f(state, event)
      assertArray fromF
      [newState, outputs] = fromF
      assertArray outputs
      state = newState
      reply = Bacon.more
      for output in outputs
        reply = @push output
        if reply == Bacon.noMore
          return reply
      reply

  decorateWith: (label, property) ->
    property.sampledBy(this, (propertyValue, streamValue) ->
        result = cloneObject(streamValue)
        result[label] = propertyValue
        result
      )

  end: (value = "end") ->
    @withHandler (event) ->
      if event.isEnd()
        @push next(value)
        @push end()
        Bacon.noMore
      else
        Bacon.more

  withHandler: (handler) ->
    new Dispatcher(@subscribe, handler).toEventStream()
  toString: -> "EventStream"

class Property extends Observable
  constructor: (@subscribe) ->
    combine = (other, leftSink, rightSink) => 
      myVal = undefined
      otherVal = undefined
      new Property (sink) =>
        unsubscribed = false
        unsubMe = nop
        unsubOther = nop
        unsubBoth = -> unsubMe() ; unsubOther() ; unsubscribed = true
        myEnd = false
        otherEnd = false
        checkEnd = ->
          if myEnd and otherEnd
            reply = sink end()
            unsubBoth() if reply == Bacon.noMore
            reply
        initialSent = false
        combiningSink = (markEnd, setValue, thisSink) =>
          (event) =>
            if (event.isEnd())
              markEnd()
              checkEnd()
              Bacon.noMore
            else if event.isError()
                reply = sink event
                unsubBoth if reply == Bacon.noMore
                reply
            else
              setValue(event.value)
              if (myVal? and otherVal?)
                if initialSent and event.isInitial()
                  # don't send duplicate Initial
                  Bacon.more
                else
                  initialSent = true
                  reply = thisSink(sink, event, myVal, otherVal)
                  unsubBoth if reply == Bacon.noMore
                  reply
              else
                Bacon.more

        mySink = combiningSink (-> myEnd = true), ((value) -> myVal = value), leftSink
        otherSink = combiningSink (-> otherEnd = true), ((value) -> otherVal = value), rightSink
        unsubMe = this.subscribe mySink
        unsubOther = other.subscribe otherSink unless unsubscribed
        unsubBoth
    @combine = (other, combinator) =>
      combineAndPush = (sink, event, myVal, otherVal) -> sink(event.apply(combinator(myVal, otherVal)))
      combine(other, combineAndPush, combineAndPush)
    @sampledBy = (sampler, combinator = former) =>
      pushPropertyValue = (sink, event, propertyVal, streamVal) -> sink(event.apply(combinator(propertyVal, streamVal)))
      combine(sampler, nop, pushPropertyValue).changes().takeUntil(sampler.end())
  sample: (interval) =>
    @sampledBy Bacon.interval(interval, {})
  map: (f) => new Property (sink) =>
    @subscribe (event) => sink(event.fmap(f))
  filter: (f) => 
    previousMathing = undefined
    new Property (sink) =>
      @subscribe (event) =>
        if event.filter(f)
          sink(event)
          previousMathing = event.value if event.hasValue()
        else if event.isInitial() and previousMathing?
          # non-matching Initial
          sink(initial(previousMathing))
        else
          Bacon.more
  endOnError: =>
    new Property (sink) =>
      @subscribe (event) =>
        if event.isError()
          reply = sink event
          if reply != Bacon.noMore
            sink end()
          Bacon.noMore
        else
          sink event
  distinctUntilChanged: => 
    new Property (sink) =>
      previous = undefined
      @subscribe (event) =>
        if !event.hasValue()
          sink(event)
        else if event.value == previous
          Bacon.more
        else
          previous= event.value
          sink(event)
  takeUntil: (stopper) => new Property(takeUntilSubscribe(this, stopper))
  changes: => new EventStream (sink) =>
    @subscribe (event) =>
      sink event unless event.isInitial()
  toProperty: => this

class Dispatcher
  constructor: (subscribe, handleEvent) ->
    subscribe ?= -> nop
    sinks = []
    @hasSubscribers = -> sinks.length > 0
    unsubscribeFromSource = nop
    removeSink = (sink) ->
      remove(sink, sinks)
    @push = (event) =>
      assertEvent event
      for sink in (cloneArray(sinks))
        reply = sink event
        removeSink sink if reply == Bacon.noMore or event.isEnd()
      if @hasSubscribers() then Bacon.more else Bacon.noMore
    handleEvent ?= (event) -> @push event
    @handleEvent = (event) => 
      assertEvent event
      handleEvent.apply(this, [event])
    @subscribe = (sink) =>
      assertFunction sink
      sinks.push(sink)
      if sinks.length == 1
        unsubscribeFromSource = subscribe @handleEvent
      assertFunction unsubscribeFromSource
      =>
        removeSink sink
        unsubscribeFromSource() unless @hasSubscribers()
  toEventStream: -> new EventStream(@subscribe)
  toString: -> "Dispatcher"

class Bus extends EventStream
  constructor: ->
    sink = undefined
    unsubFuncs = []
    inputs = []
    guardedSink = (input) => (event) =>
      if (event.isEnd())
        remove(input, inputs)
        Bacon.noMore
      else
        sink event
    unsubAll = => 
      f() for f in unsubFuncs
      unsubFuncs = []
    subscribeAll = (newSink) =>
      sink = newSink
      unsubFuncs = []
      for input in inputs
        unsubFuncs.push(input.subscribe(guardedSink(input)))
      unsubAll
    dispatcher = new Dispatcher(subscribeAll)
    subscribeThis = (sink) =>
      dispatcher.subscribe(sink)
    super(subscribeThis)
    @plug = (inputStream) =>
      inputs.push(inputStream)
      if (sink?)
        unsubFuncs.push(inputStream.subscribe(guardedSink(inputStream)))
    @push = (value) =>
      sink next(value) if sink?
    @error = (error) =>
      sink new Error(error) if sink?
    @end = =>
      unsubAll()
      sink end()

Bacon.EventStream = EventStream
Bacon.Property = Property
Bacon.Bus = Bus
Bacon.Initial = Initial
Bacon.Next = Next
Bacon.End = End
Bacon.Error = Error

takeUntilSubscribe = (src, stopper) -> 
  (sink) ->
    unsubscribed = false
    unsubSrc = nop
    unsubStopper = nop
    unsubBoth = -> unsubSrc() ; unsubStopper() ; unsubscribed = true
    srcSink = (event) ->
      if event.isEnd()
        unsubStopper()
      reply = sink event
      if reply == Bacon.noMore
        unsubStopper()
      reply
    stopperSink = (event) ->
      if event.isError()
        Bacon.more
      else if event.isEnd()
        Bacon.noMore
      else
        unsubSrc()
        sink end()
        Bacon.noMore
    unsubStopper = stopper.subscribe(stopperSink)
    unsubSrc = src.subscribe(srcSink) unless unsubscribed
    unsubBoth

nop = ->
latter = (_, x) -> x
former = (x, _) -> x
initial = (value) -> new Initial(value)
next = (value) -> new Next(value)
end = -> new End()
isEvent = (x) -> x? and x.isEvent? and x.isEvent()
toEvent = (x) -> 
  if isEvent x
    x
  else
    next x
empty = (xs) -> xs.length == 0
head = (xs) -> xs[0]
tail = (xs) -> xs[1...xs.length]
filter = (f, xs) ->
  filtered = []
  for x in xs
    filtered.push(x) if f(x)
  filtered
map = (f, xs) ->
  f(x) for x in xs
cloneArray = (xs) -> xs.slice(0)
cloneObject = (src) ->
  clone = {}
  for key, value of src
    clone[key] = value
  clone
remove = (x, xs) ->
  i = xs.indexOf(x)
  if i >= 0
    xs.splice(i, 1)
assert = (message, condition) -> throw message unless condition
assertEvent = (event) -> assert "not an event : " + event, event.isEvent? ; assert "not event", event.isEvent()
assertFunction = (f) -> assert "not a function : " + f, typeof f == "function"
assertArray = (xs) -> assert "not an array : " + xs, xs instanceof Array

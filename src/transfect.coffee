transfectAttribute = "data-transfect"
transfectBaseScope = window

debug = true

window.Transfect = {}

isComponent = (element) ->
  typeof element.type != 'string'

camelify =
  'class': 'className'
  'classname': 'className'
  'onchange': 'onChange'
  'onclick': 'onClick'

invariant = (condition, message) ->
  if debug && ! condition
    throw message

applyBind = (bindPoint, toBind, element) ->
  resultingElement =
    switch
      when ! bindPoint?
        invariant element.type, "Trying to replace an element with a non-element: #{element}."

        toBind

      when bindPoint.match /^\$/
        invariant isComponent(element), "Trying to bind props to an HTML element."

        React.cloneElement(element, { data: toBind })

      when bindPoint.match /^\[/
        attribute = bindPoint.substring(1, bindPoint.length - 1)

        updateObject = {}
        updateObject[camelify[attribute] || attribute] = toBind

        React.cloneElement(element, updateObject)

      when bindPoint.match /^%/
        React.cloneElement(
          element,
          children: React.Children.map(element.props.children, (child) ->
            if typeof child == 'string'
              child.replace ///(?=\W)#{bindPoint}(?=\W)///g, toBind
            else
              child
          )
        )

      when bindPoint == "*"
        React.cloneElement(element, children: toBind)

  if resultingElement.props[transfectAttribute]?
    parseComponents resultingElement, true
  else
    resultingElement

compileBind = (context, bindPoint, transform) ->
  (element) ->
    # For now, functions attached to event handlers are not considered
    # transformations. Other functions are, and are executed in the passed
    # context and given the element that's being transformed.
    toBind =
      if typeof transform == 'function' && ! bindPoint?.match /^\[on/
        transform.call context, element
      else if typeof transform == "undefined"
        []
      else
        transform

    if Array.isArray(toBind)
      for bindValue in toBind
        applyBind bindPoint, bindValue, element
    else if Immutable?.List?.isList(toBind) || Immutable?.Seq?.isSeq(toBind)
      toBind
        .map((_) ->
          applyBind(bindPoint, _, element))
        .toArray()
    else
      [applyBind(bindPoint, toBind, element)]

window.pushInArray = (container, key, value) ->
  innerContainer = container[key] || []
  innerContainer.push(value)
  container[key] = innerContainer

Transfect.compileTransform = compileTransform = (context, transformSpec) ->
  keys = (key for key of transformSpec)

  topLevel = []
  byId = {}
  byClass = {}
  byTag = {}
  byType = {}

  for spec, transform of transformSpec
    [selector, bindPoint] = spec.split ' '

    applierFn = compileBind(context, bindPoint, transform)
    applierFn._generatingSpec = [spec, transform]

    switch
      when selector == '^'
        topLevel.push applierFn
      when selector.match /^\./
        pushInArray byClass, selector.substring(1), applierFn
      when selector.match /^#/
        pushInArray byId, selector.substring(1), applierFn
      when selector.match /^@/
        pushInArray byType, selector.substring(1), applierFn
      else
        pushInArray byTag, selector, applierFn

  runTransform = (element, childInvocation = false) ->
    if typeof element == 'string'
      # Text nodes are transformed by their parent.
      text = element
      clearedLeadingWhitespace = text.replace(/^\s+/g, '')

      if clearedLeadingWhitespace.length > 0
        [clearedLeadingWhitespace]
      else
        []
    else
      applicableBinds =
        if ! childInvocation
          topLevel.slice()
        else
          base = []
          if element.props.type? && byType[element.props.type]?
            base.push.apply base, byType[element.props.type]
          if byTag[element.type] || byTag[element.type.displayName]
            base.push.apply base, byTag[element.type] || byTag[element.type.displayName]
          if element.props.id? && byId[element.props.id]
            base.push.apply base, byId[element.props.id]
          if element.props.classes
            for className in element.props.classes when byClass[className]
              base.push.apply base, byClass[className]

          base

      transformed =
        applicableBinds.reduce(
          (elements, bind) ->
            collectedTransformedElements = []
            # O flatMap, where art thou.
            for element in elements
              collectedTransformedElements.push.apply(
                collectedTransformedElements,
                bind(element)
              )

            collectedTransformedElements
          [element]
        )

      for element in transformed
        if ! isComponent(element)
          collectedChildren = []
          React.Children.forEach element.props.children, (child) ->
            collectedChildren.push.apply collectedChildren, runTransform(child, true)

          React.cloneElement(
            element,
            children: if collectedChildren.length > 0 then collectedChildren else null
          )
        else
          # TODO Consider traversing into a single component child to apply
          # TODO things to it if it makes sense by selector.
          element

baseRender = ->
  compiledTransform = compileTransform this, @transform()

  baseElement = React.Children.only @props.children

  compiledTransform(baseElement)[0]

window.Transfect.createComponent = (body, args...) ->
  invariant ! body.render?, "Use transform to define your rendering behavior for a Transfect component."

  withRender = { render: baseRender }
  for key, value of body
    withRender[key] = value

  React.createClass.apply React, [withRender].concat(args)

## Given a React element structure, parse out a transfect component invocation,
## if it exists, and insert a component accordingly.
parseComponents = (element, recurse = false) ->
  attributes = element.props

  if recurse
    attributes.children =
      React.Children.map(
        attributes.children,
        (child) ->
          if child.props?
            parseComponents(child, true)
          else
            child
      )

  componentName = attributes[transfectAttribute]
  if componentName
    reactProps = {}
    finalAttributes = {}
    for attribute of attributes when attribute != transfectAttribute
      if attribute.match /^data-/
        reactProps[attribute.substring(5)] = attributes[attribute]
      else if attribute == 'classes' || attribute == 'className' || attribute == 'id'
        reactProps[attribute] = finalAttributes[attribute] = attributes[attribute]
      else
        finalAttributes[camelify[attribute] || attribute] = attributes[attribute]

    newElement =
      React.createElement element.type, finalAttributes

    component =
      componentName
        .split('.')
        .reduce ((scope, name) -> scope[name]), transfectBaseScope

    invariant component?, "Failed to find component #{componentName}."

    React.createElement component, reactProps, newElement
  else
    React.cloneElement(element, attributes)

reactify = (rootNode) ->
  # TODO Multimethod?
  if rootNode.nodeType == Node.TEXT_NODE
    rootNode.textContent
  else
    tag = rootNode.tagName
    elementAttributes = rootNode.attributes

    attributes = {}
    for elementAttribute in elementAttributes
      attributes[elementAttribute.nodeName] = elementAttribute.nodeValue

    children = (reactify(childNode) for childNode in rootNode.childNodes)

    if attributes['class']?
      attributes.className = attributes['class']
      attributes.classes = attributes['class'].split ' '
      delete attributes['class']

    parseComponents(
      React.createElement.apply(
        React,
        [tag.toLowerCase(), attributes].concat(children)
      )
    )

window.transfect = (template, mountLocation) ->
  templateElement =
    if typeof template == 'string'
      document.getElementById(template)
    else
      template

  reacted = reactify(templateElement)

  ReactDOM.render(reacted, mountLocation || templateElement)

transfectAttribute = "data-transfect"
transfectBaseScope = window

debug = true

isComponent = (element) ->
  typeof element.type != 'string'

camelify =
  'class': 'className'
  'classname': 'className'
  'onchange': 'onChange'
  'onclick': 'onClick'

applyBind = (bindPoint, toBind, element) ->
  switch
    when bindPoint.match /^\$/
      if debug && ! isComponent(element)
        throw "Trying to bind props to an HTML element."

      React.cloneElement(element, toBind)

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

compileBind = (context, bindPoint, transform) ->
  (element) ->
    # For now, functions attached to event handlers are not considered
    # transformations. Other functions are, and are executed in the passed
    # context and given the element that's being transformed.
    toBind =
      if typeof transform == 'function' && ! bindPoint.match /^\[on/
        transform.call context, element
      else
        transform

    if Array.isArray(toBind)
      for bindValue in toBind
        applyBind bindPoint, bindValue, element
    else
      [applyBind(bindPoint, toBind, element)]

window.pushInArray = (container, key, value) ->
  innerContainer = container[key] || []
  innerContainer.push(value)
  container[key] = innerContainer

compileTransform = (context, transformSpec) ->
  keys = (key for key of transformSpec)

  byId = {}
  byClass = {}
  byTag = {}
  byType = {}

  for spec, transform of transformSpec
    [selector, bindPoint] = spec.split ' '

    applierFn = compileBind(context, bindPoint, transform)

    if selector.match /^\./
      pushInArray byClass, selector.substring(1), applierFn
    else if selector.match /^#/
      pushInArray byId, selector.substring(1), applierFn
    else if selector.match /^@/
      pushInArray byType, selector.substring(1), applierFn
    else
      pushInArray byTag, selector, applierFn

  runTransform = (element) ->
    if typeof element == 'string'
      # Text nodes are transformed by their parent.
      [element]
    else
      applicableBinds = []
      if element.props.type? && byType[element.props.type]?
        applicableBinds.push.apply applicableBinds, byType[element.props.type]
      if byTag[element.type]
        applicableBinds.push.apply applicableBinds, byTag[element.type]
      if element.props.id? && byId[element.props.id]
        applicableBinds.push.apply applicableBinds, byId[element.props.id]
      if element.props.classes
        for className in element.props.classes when byClass[className]
          applicableBinds.push.apply applicableBinds, byClass[className]

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
            collectedChildren.push.apply collectedChildren, runTransform(child)

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

  transformedChildren = []
  React.Children.forEach baseElement.props.children, (element) ->
    transformedChildren.push.apply transformedChildren, compiledTransform(element)

  React.cloneElement(baseElement, children: transformedChildren)

window.Transfect =
  createComponent: (body, args...) ->
    if body.render
      throw "Use transform to define your rendering behavior for a Transfect component."

    withRender = { render: baseRender }
    for key, value of body
      withRender[key] = value

    React.createClass.apply React, [withRender].concat(args)

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

    componentName = attributes[transfectAttribute]
    if componentName
      reactProps = {}
      finalAttributes = {}
      for attribute of attributes
        if attribute.match /^data-/
          reactProps[attribute.substring(5)] = attributes[attribute]
        else if attribute == 'class'
          reactProps.className = finalAttributes.className = attributes[attribute]
          reactProps.classes = attributes[attribute].split ' '
        else
          finalAttributes[camelify[attribute]] = attributes[attribute]

      element =
        React.createElement.apply(
          React,
          [tag.toLowerCase(), finalAttributes].concat(children)
        )

      component =
        componentName
          .split('.')
          .reduce ((scope, name) -> scope[name]), transfectBaseScope

      React.createElement component, reactProps, element
    else
      if attributes['class']?
        attributes.classes = attributes['class'].split ' '

      React.createElement.apply(
        React,
        [tag.toLowerCase(), attributes].concat(children)
      )

window.transfect = (template, mountLocation) ->
  templateElement =
    if typeof template == 'string'
      document.getElementById(template)
    else
      template

  reacted = reactify(templateElement)

  ReactDOM.render(reacted, mountLocation || templateElement)

## # Renderer
## 
## Provides a single-page application (SPA) renderer with reactivity features.
## It likely contains functions or classes that allow developers to
## dynamically update the content of a web page without reloading the entire page.

import
  macros,
  logging,
  htmlgen,
  strtabs,
  sugar,
  strutils,
  strformat,
  tables,
  regex,
  ./tag,
  ../private/cmpltime

when defined(js):
  import
    dom,
    jsconsole
  export
    dom,
    jsconsole

export
  strformat,
  logging,
  htmlgen,
  strtabs,
  strutils,
  tables,
  regex,
  sugar,
  tag


type
  AppEventHandler* = proc()
  ComponentEventHandler* = proc(self: BaseComponent)
  App* = ref object
    appId*: string
    router*: proc()
  BaseComponent* = ref BaseComponentObj
  BaseComponentObj* = object of RootObj


# Global variables
var
  application*: App = nil
  eventHandlers* = newTable[int, AppEventHandler]()
  componentEventHandlers* = newTable[int, ComponentEventHandler]()
  components* = newTable[cstring, BaseComponent]()

# Compile time variables
var
  uniqueId {.compileTime.} = 0


when defined(js):
  {.emit: "function callEventHandler(idx) {".}
  var idx: int
  {.emit: "`idx` = idx;" .}
  eventHandlers[idx]()
  {.emit: "}" .}
  {.emit: "function callComponentEventHandler(componentId, idx) {".}
  var
    callbackIdx: int
    componentId: cstring
  {.emit: "`callbackIdx` = idx; `componentId` = componentId;" .}
  componentEventHandlers[callbackIdx](components[componentId])
  {.emit: "}" .}


proc route*(path: cstring) {. inline .} =
  when defined(js):
    {.emit: "window.history.pushState(null, null, '#' + `path`);" .}
    application.router()


proc registerApp*(appId: string = "app"): App {. discardable, inline .} =
  ## Creates a new Singla Page Application
  application = App(appId: appId)
  application


proc registerComponent*(name: string, component: BaseComponent): BaseComponent {. inline .} =
  if components.hasKey(name):
    return components[name]
  components[name] = component
  return component


func render*(self: var BaseComponent): TagRef {. inline .} =
  ## Basic function that needs to overload
  nil


template start*(app: App) =
  ## Starts single page application
  document.addEventListener("DOMContentLoaded", onDOMContentLoaded)
  window.addEventListener("popstate", onDOMContentLoaded)


proc replaceIter*(
    root: NimNode,
    search: proc(x: NimNode): bool,
    replace: proc(x: NimNode): NimNode
): bool {. compileTime .} =
  result = false
  for i in 0..root.len-1:
    result = root[i].replaceIter(search, replace)
    if search(root[i]):
      root[i] = replace(root[i])
      result = true


proc getTagName*(name: string): string {. compileTime .} =
  ## Checks tag name at compile time
  ## 
  ## tagDiv, tDiv, hDiv -> div
  if re"^tag[A-Z]" in name:
    name[3..^1].toLower()
  elif re"^[ht][A-Z]" in name:
    name[1..^1].toLower()
  else:
    name


proc attribute(attr: NimNode): NimNode {. compileTime .} =
  newColonExpr(
    newStrLitNode($attr[0]),
    if attr[1].kind in [nnkStrLit, nnkTripleStrLit]:
      newCall("fmt", attr[1])
    else:
      attr[1]
  )


proc addAttribute(node, key, value: NimNode) {. compileTime .} =
  if node.len == 2:
    node.add(newCall("newStringTable", newNimNode(nnkTableConstr).add(
      newColonExpr(newStrLitNode($key), value)
    )))
  elif node[2][1].kind == nnkTableConstr:
    node[2][1].add(newColonExpr(newStrLitNode($key), value))
  else:
    node.insert(2, newCall("newStringTable", newNimNode(nnkTableConstr).add(
      newColonExpr(newStrLitNode($key), value)
    )))


proc endsWithBuildHtml(statement: NimNode): bool {. compileTime .} =
  statement[^1].kind == nnkCall and $statement[^1][0] == "buildHtml"


proc replaceSelfComponent(statement, componentName: NimNode) {. compileTime .} =
  if statement.kind == nnkDotExpr:
    if $statement[0] == "self":
      statement[0] = newDotExpr(ident("self"), componentName)
    return
  
  for i in statement.children:
    i.replaceSelfComponent(componentName)


proc replaceSelfStateVal(statement: NimNode) {. compileTime .} =
  for idx, i in statement.pairs:
    if i.kind == nnkDotExpr:
      if $i[0] == "self":
        statement[idx] = newCall("get", newDotExpr(i[0], i[1]))
      continue
    if i.kind in RoutineNodes:
      continue
    i.replaceSelfStateVal()


proc buildHtmlProcedure*(root, body: NimNode, inComponent: bool = false,
                         componentName: NimNode = newEmptyNode()): NimNode {. compileTime .} =
  ## Builds HTML
  let elementName = newStrLitNode(getTagName($root))
  result = newCall("initTag", elementName)

  for statement in body:
    if statement.kind == nnkCall:
      let
        tagName = newStrLitNode(getTagName($statement[0]))
        statementList = statement[^1]
      var attrs = newNimNode(nnkTableConstr)
      # tag(attr="value"):
      #   ...
      if statement.len-2 > 0 and statementList.kind == nnkStmtList:
        for attr in statement[1 .. statement.len-2]:
          attrs.add(attribute(attr))
        var builded = buildHtmlProcedure(tagName, statementList, inComponent, componentName)
        builded.insert(2, newCall("newStringTable", attrs))
        result.add(builded)
      # tag(attr="value")
      elif statementList.kind != nnkStmtList:
        for attr in statement[1 .. statement.len-1]:
          attrs.add(attribute(attr))
        if attrs.len > 0:
          result.add(newCall("initTag", tagName, newCall("newStringTable", attrs)))
        else:
          result.add(newCall("initTag", tagName))
      # tag:
      #   ...
      else:
        result.add(buildHtmlProcedure(tagName, statementList, inComponent, componentName))
    
    elif statement.kind == nnkCommand:
      # Component usage
      if $statement[0] == "component":
        let
          name =
            if statement[1].kind == nnkCall:
              statement[1][0]
            else:
              statement[1]
          objConstr = newNimNode(nnkObjConstr).add(name)
          componentName = fmt"comp{name}{uniqueId}{uniqueId + 2}{uniqueId * 2}{uniqueId + 7}"
          componentNameTmp = "_" & componentName
          componentData = "data_" & componentName
        inc uniqueId
        if statement[1].kind == nnkCall:
          for i in 1..<statement[1].len:
            objConstr.add(newNimNode(nnkExprColonExpr).add(
              statement[1][i][0], newCall("remember", statement[1][i][1])
            ))
        objConstr.add(newNimNode(nnkExprColonExpr).add(
          ident("uniqCompId"), newStrLitNode(componentName)
        ))
        result.add(newStmtList(
          newVarStmt(ident(componentNameTmp), objConstr),
          newVarStmt(
            ident(componentName),
            newCall(
              name,
              newCall("registerComponent", newStrLitNode(componentName), ident(componentNameTmp))
            )
          ),
          newLetStmt(
            ident(componentData),
            newCall("render", ident(componentName))
          ),
          newCall(
            "addArgIter",
            ident(componentData),
            newCall("&", newStrLitNode("data-"), newDotExpr(ident(componentName), ident("uniqCompId")))
          ),
          ident(componentData)
        ))
    
    elif statement.kind in [nnkStrLit, nnkTripleStrLit]:
      # "Raw text"
      result.add(newCall("initTag", newCall("fmt", statement), newLit(true)))
    
    elif statement.kind == nnkAsgn:
      # Attributes
      result.addAttribute(statement[0], statement[1])
    
    # Events handling
    elif statement.kind == nnkPrefix and $statement[0] == "@":
      let
        event = $statement[1]
        args = newNimNode(nnkFormalParams).add(
          newEmptyNode()
        )
        procedure = newNimNode(nnkLambda).add(
          newEmptyNode(), newEmptyNode(), newEmptyNode(), args,
          newEmptyNode(), newEmptyNode(),
          newStmtList()
        )
      
      if inComponent:
        statement[2].replaceSelfComponent(componentName)
        procedure.body = statement[2]
        args.add(newIdentDefs(ident("self"), ident("BaseComponent")))
        result.addAttribute(
          newStrLitNode(fmt"on{event}"),
          newCall(
            "fmt",
            newStrLitNode("callComponentEventHandler('{self.uniqCompId}', " & fmt"{uniqueId})")
          )
        )
        result.add(newStmtList(
          newCall("once",
            newCall("[]=", ident("componentEventHandlers"), newIntLitNode(uniqueId), procedure)
          ), newNilLit()
        ))
      else:
        procedure.body = statement[2]
        result.addAttribute(
          newStrLitNode(fmt"on{event}"),
          newStrLitNode(fmt"callEventHandler({uniqueId})")
        )
        result.add(newStmtList(
          newCall("once",
            newCall("[]=", ident("eventHandlers"), newIntLitNode(uniqueId), procedure)
          ), newNilLit()
        ))
      inc uniqueId
    
    elif statement.kind == nnkIdent:
      # tag
      result.add(newCall("tag", newStrLitNode(getTagName($statement))))
    
    elif statement.kind == nnkAccQuoted:
      # `tag`
      result.add(newCall("tag", newStrLitNode(getTagName($statement[0]))))
    
    elif statement.kind == nnkCurly and statement.len == 1:
      # variables
      result.add(newCall("initTag", newCall("$", statement[0]), newLit(true)))
    
    # if-elif or case-of
    elif statement.kind in [nnkCaseStmt, nnkIfStmt, nnkIfExpr]:
      let start =
        if statement.kind == nnkCaseStmt:
          1
        else:
          0
      for i in start..<statement.len:
        statement[i][^1] = buildHtmlProcedure(
          ident("div"), statement[i][^1], inComponent, componentName
        ).add(newLit(true))
      if statement[^1].kind != nnkElse:
        statement.add(newNimNode(nnkElse).add(newNilLit()))
      result.add(statement)
    
    # for ... in ...:
    #   ...
    elif statement.kind == nnkForStmt:
      let
        arguments = collect(newSeq):
          for i in statement[0..statement.len-3]:
            $i
      # nnkCall
      var replaced = statement[^1].replaceIter(
        (x) => x.kind == nnkCall and $x[0] in arguments,
        proc(x: NimNode): NimNode =
          let stmtList = x[^1]
          var
            builded: NimNode
            attrs = newNimNode(nnkTableConstr)
          if stmtList.kind == nnkStmtList:
            builded = buildHtmlProcedure(x[0], x[^1], inComponent, componentName)
            # tag(attr="value"):
            #   ...
            for attr in x[1 .. x.len-2]:
              attrs.add(attribute(attr))
          else:
            builded = buildHtmlProcedure(x[0], newStmtList(), inComponent, componentName)
            # tag(attr="value"):
            #   ...
            for attr in x[1 .. x.len-1]:
              attrs.add(attribute(attr))
          builded.insert(2, newCall("newStringTable", attrs))
          newNimNode(nnkIfExpr).add(
            newNimNode(nnkElifExpr).add(
              newCall("is", newCall("typeof", x[0]), ident("string")),
              builded
            )
          )
      )
      if not replaced:
        # nnkIdent
        replaced = statement[^1].replaceIter(
          (x) => x.kind == nnkIdent and $x in arguments,
          (x) => newNimNode(nnkIfExpr).add(
            newNimNode(nnkElifExpr).add(
              newCall("is", newCall("typeof", x), ident("string")),
              newCall("initTag", x)
            )
          )
        )
      # as varibale with {}
      discard statement[^1].replaceIter(
        (x) => x.kind == nnkCurly and x.len == 1 and x[0].kind == nnkIdent and $x[0] in arguments,
        (x) => newCall("initTag", newCall("$", x[0]), newLit(true))
      )
      result.add(
        newCall(
          "initTag",
          newStrLitNode("div"),
          newCall(
            "collect",
            ident("newSeq"),
            newNimNode(nnkStmtList).add(statement)
          ),
          newLit(true)
        )
      )
  
  # varargs -> seq
  if result.len > 2:
    if result[2].kind == nnkCall and $result[2][0] == "newStringTable":
      var
        tagRefs = result[3..result.len-1]
        arr = newNimNode(nnkBracket)
      result.del(3, result.len - 3)
      for tag in tagRefs:
        arr.add(tag)
      result.add(newCall("@", arr))
    else:
      var
        tagRefs = result[2..result.len-1]
        arr = newNimNode(nnkBracket)
      result.del(2, result.len - 2)
      for tag in tagRefs:
        arr.add(tag)
      result.add(newCall("@", arr))


macro buildHtml*(root, html: untyped): untyped =
  ## `buildHtml` macro provides building HTML tags with YAML-like syntax.
  ## 
  ## Args:
  ## - `root`: root element. It's can be `tag`, tag or tTag
  ## - `html`: YAML-like structure.
  ## 
  ## Syntax support:
  ##   - attributes via exprEqExpr
  ##   
  ##     .. code-block:: nim
  ##        echo buildHtml(`div`):
  ##          h1(class="myClass", align="center")
  ##          input(`type`="password", align="center")
  ##   
  ##   - nested tags
  ##   
  ##     .. code-block:: nim
  ##        echo buildHtml(`div`):
  ##          tag:
  ##            tag1:
  ##              tag2:
  ##            tag1withattrs(attr="value")
  ##   
  ##   - if-elif-else expressions
  ## 
  ##     .. code-block:: nim
  ##        var state = true
  ##        echo buildHtml(`div`):
  ##          if state:
  ##            "True!"
  ##          else:
  ##            "False("
  ##   
  ##   - for statements
  ## 
  ##     .. code-block:: nim
  ##        var state = @["h1", "h2", "input"]
  ##        echo buildHtml(`div`):
  ##          for i in state:
  ##            i
  ## 
  buildHtmlProcedure(root, html)


macro buildHtml*(html: untyped): untyped =
  ## `buildHtml` macro provides building HTML tags with YAML-like syntax.
  ## This macro doesn't generate Root tag
  ## 
  ## Args:
  ## - `html`: YAML-like structure.
  ## 
  result = buildHtmlProcedure(ident("tDiv"), html)
  if result[^1].kind == nnkCall and $result[^1][0] == "@":
    result.add(newLit(true))


macro buildComponentHtml*(componentName, html: untyped): untyped =
  ## `buildHtml` macro provides building HTML tags with YAML-like syntax.
  ## This macro doesn't generate Root tag
  ## 
  ## Args:
  ## - `html`: YAML-like structure.
  ## 
  result = buildHtmlProcedure(ident("tDiv"), html, true, componentName)


macro routes*(app: App, body: untyped): untyped =
  ## Provides JS router for Single page application
  let
    iPath = ident("path")
    iHtml = ident("html")
    iRouter = ident("callRouter")
    router = newProc(postfix(iRouter, "*"))
    onDOMContentLoaded = newProc(
      ident("onDOMContentLoaded"),
      [newEmptyNode(), newIdentDefs(ident("ev"), ident("Event"))]
    )
    ifStmt = newNimNode(nnkIfStmt)

  # On DOM Content Loaded
  onDOMContentLoaded.body = newStmtList(newCall(iRouter))
  router.body = newStmtList()

  # Router
  router.body.add(
    newLetStmt(
      ident("elem"),
      newCall("getElementById", ident("document"), newDotExpr(ident("app"), ident("appId")))
    ),
    newLetStmt(
      ident("path"),
      newCall(
        "strip",
        newCall("$", newDotExpr(newDotExpr(ident("window"), ident("location")), ident("hash"))),
        newLit(true),
        newLit(false),
        newNimNode(nnkCurly).add(newLit('#'))
      )
    ),
    newNimNode(nnkVarSection).add(newIdentDefs(
      iHtml, ident("TagRef"), newNilLit()
    ))
  )

  for statement in body:
    if statement.kind in [nnkCommand, nnkCall]:
      if statement.len == 2 and statement[0].kind == nnkStrLit:
        let exported = exportRouteArgs(
          iPath,
          statement[0],
          statement[1]
        )
        # Route contains params
        if exported.len > 0:
          for i in 0..<statement[1].len:
            exported[^1].del(exported[^1].len-1)
          exported[^1] = newStmtList(
            exported[^1],
            newAssignment(
              iHtml,
              if statement[1].endsWithBuildHtml:
                statement[1]
              else:
                newCall("buildHtml", statement[1])
            )
          )
          ifStmt.add(exported)
        # Route doesn't contains any params
        else:
          ifStmt.add(newNimNode(nnkElifBranch).add(
            newCall("==", iPath, statement[0]),
            newAssignment(
              iHtml,
              if statement[1].endsWithBuildHtml:
                statement[1]
              else:
                newCall("buildHtml", statement[1])
            )
          ))
      elif statement[1].kind == nnkStmtList and statement[0].kind == nnkIdent:
        case $statement[0]
        of "notfound":
          if statement[1].endsWithBuildHtml:
            router.body.add(
              newAssignment(iHtml, statement[1])
            )
          else:
            router.body.add(
              newAssignment(iHtml, newCall("buildHtml", statement[1]))
            )
  
  if ifStmt.len > 0:
    router.body.add(ifStmt)
  
  router.body.add(
    newNimNode(nnkIfStmt).add(newNimNode(nnkElifBranch).add(
      newCall("not", newCall("isNil", iHtml)),
      newStmtList(
        newAssignment(
          newDotExpr(ident("elem"), ident("innerHTML")),
          newCall("$", iHtml)
        )
      )
    ))
  )

  newStmtList(
    router,
    newAssignment(newDotExpr(ident("app"), ident("router")), router.name),
    onDOMContentLoaded
  )


macro component*(name, body: untyped): untyped =
  ## Register a new component.
  ## 
  ## Returns string
  ## 
  let
    name = $name
    nameObj = $name & "Obj"
    params = newNimNode(nnkRecList)
  
  var
    templateStmtList = newStmtList()
    scriptStmtList = newStmtList()
    styleStmtList = newStmtList()
  
  params.add(
    newNimNode(nnkIdentDefs).add(
      postfix(ident("uniqCompId"), "*"),
      bindSym("string"),
      newEmptyNode()
    ),
  )
  
  for s in body.children:
    if s.kind == nnkCall:
      if s[0].kind == nnkIdent and s.len == 2 and s[^1].kind == nnkStmtList and s[^1].len == 1:
        params.add(newNimNode(nnkIdentDefs).add(
          postfix(s[0], "*"), newCall(
            bindSym("[]", brForceOpen), ident("State"), s[1][0]
          ), newEmptyNode()
        ))
    
      elif s[0].kind == nnkAccQuoted:
        case $s[0]
        of "template":
          templateStmtList = newStmtList(
            newCall("script", ident("self")),
            newAssignment(
              ident("result"),
              newCall(
                "buildComponentHtml",
                ident(name),
                s[1].add(newCall(
                  "style", newStmtList(newStrLitNode("{self.style()}"))
                ))
              )
            ),
          )
        of "style":
          let str = ($s[1][0]).replace(
            re"^([\S ]+?) *\{(?im)", "$1[data-{self.uniqCompId}]{{"
          ).replace(re"(^ *|\{ *|\n *)\}(?im)", "$1}}")
          echo str
          styleStmtList = newStmtList(
            newAssignment(
              ident("result"),
              newCall("fmt", newStrLitNode(str))
            )
          )
        of "script":
          s[1].replaceSelfStateVal()
          scriptStmtList = s[1]
          echo treeRepr s[1]

  result = newStmtList(
    newNimNode(nnkTypeSection).add(
      newNimNode(nnkTypeDef).add(
        postfix(ident(nameObj), "*"),  # name
        newEmptyNode(),
        newNimNode(nnkObjectTy).add(
          newEmptyNode(),  # no pragma
          newNimNode(nnkOfInherit).add(ident("BaseComponentObj")),
          params
        )
      ),
      newNimNode(nnkTypeDef).add(
        postfix(ident(name), "*"),  # name
        newEmptyNode(),
        newNimNode(nnkRefTy).add(ident(nameObj))
      )
    ),
    newProc(
      ident("script"),
      [
        newEmptyNode(),
        newIdentDefs(ident("self"), ident(name))
      ],
      scriptStmtList
    ),
    newProc(
      ident("style"),
      [
        ident("string"),
        newIdentDefs(ident("self"), ident(name))
      ],
      styleStmtList
    ),
    newProc(
      postfix(ident("render"), "*"),
      [
        ident("TagRef"),
        newIdentDefs(ident("self"), ident(name))
      ],
      templateStmtList
    ),
  )

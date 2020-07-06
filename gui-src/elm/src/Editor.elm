module Editor exposing (..)

import Set exposing (Set)

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Element.Events as Events

import Html.Events as HtmlEvents
import Html.Attributes as HtmlAttributes

import Slice exposing (..)
import LocalSlice exposing (..)
import Palette exposing (..)
import EditorField

import Dict exposing (Dict)

-- | MODEL: Editor State
type alias Node =
  { hovered: Bool
  , marked: Bool
  , id: SliceID
  , children: Children
  , content: NodeContent
  , editable: Bool
  , framed: Bool
  , changed: Bool
  }

type Children = Collapsed | Expanded (List Node)

defaultNode : Node
defaultNode =
  { hovered = False
  , marked = False
  , id = ""
  , children = Collapsed
  , content = Occurences []
  , editable = False
  , framed = False
  , changed = False
  }

type NodeContent
 = SliceNode SliceWrap
 | Occurences (List SliceWrap)
 | Dependencies (List SliceWrap)

-- | Helpers
mapNode : (Node -> Node) -> Node -> Node
mapNode f node =
  case node.children of
    Collapsed ->
      f node
    Expanded nodes ->
      f { node | children = Expanded (List.map (mapNode f) nodes) }

foldNode : (Node -> a -> a) -> a -> Node -> a
foldNode f z node =
    case node.children of
      Collapsed ->
        f node z
      Expanded nodes ->
        let
          z2 =
            List.foldl
              (\x acc ->
                foldNode f acc x)
              z
              nodes
        in
          f node z2


updateNodeContents : Dict SliceID SliceWrap -> Cache -> Node -> Result String Node
updateNodeContents updates cache node =
  case node.content of
    SliceNode sw ->
      case Dict.get sw.id updates of
        Nothing ->
          updateNodeChildren updates cache node
        Just newSw ->
          let
            newContent = SliceNode newSw
            newId =
              (String.dropRight (String.length sw.id) node.id)
              ++ newSw.id
            newChildren = case node.children of
              Collapsed -> Collapsed
              Expanded cs -> Expanded
                (List.map
                  (mapNode (\n ->
                    {n | id = newId ++ (String.dropLeft ((String.length node.id) + 1) n.id)}
                  ))
                  cs)
          in
            updateOccsDeps newSw cache { node | content = newContent, id = newId, children = newChildren }
            |> Result.andThen (updateNodeChildren updates cache)
    Occurences occs ->
      updateNodeChildren updates cache node
      |> Result.map (updateWhichChildren occs)
    Dependencies deps ->
      updateNodeChildren updates cache node
      |> Result.map (updateWhichChildren deps)

updateNodeChildren : Dict SliceID SliceWrap -> Cache -> Node -> Result String Node
updateNodeChildren updates cache node =
  case node.children of
    Collapsed ->
      Ok node
    Expanded children ->
      List.map (updateNodeContents updates cache) children
      |> combineResults
      |> Result.mapError String.concat
      |> Result.map (\newKids -> { node | children = Expanded newKids })

updateOccsDeps : SliceWrap -> Cache -> Node -> Result String Node
updateOccsDeps { occurences, slice } cache node =
  case node.children of
    Collapsed -> Ok node
    Expanded children ->
      let
        replaceChild n =
          case n.content of
            Occurences _ ->
              fetchMap cache occurences
              |> Result.map (\occs -> { n | content = Occurences occs} )
            Dependencies _ ->
              fetchMap cache (extractDependencies slice)
              |> Result.map (\deps -> { n | content = Dependencies deps} )
            _ -> Ok n
      in
        List.map replaceChild children
        |> combineResults
        |> Result.mapError String.concat
        |> Result.map (\newChildren -> { node | children = Expanded newChildren })

updateWhichChildren : List SliceWrap -> Node -> Node
updateWhichChildren children node =
  case node.children of
    Collapsed -> node
    Expanded cs ->
      let
        additionalChildren =
          List.filter (\{id} -> not (List.any (\n -> String.endsWith id n.id) cs)) children
          |> List.map
              (\sw ->
                { defaultNode |
                    id = node.id ++ sw.id
                    , content = SliceNode sw
                }
              )

        newChildIds =
          List.map .id children

        filteredChildren =
          List.filter
            (\{content} -> case content of
              SliceNode {id} -> List.member id newChildIds
              _               -> False )
            cs
      in
        { node | children = Expanded (additionalChildren ++ filteredChildren) }



-- | UPDATE
-- Sometimes the editor needs to send a Msg to its parent, e.g. when slices
-- are to be updated
type Msg
  = Main MainAction
  | Editor EditorAction

type MainAction
  = TextEdit String SliceWrap
  | DependencyRemove SliceID SliceWrap

type alias EditorAction =
  { target: String
  , action: Action
  }

type Action
  = Expand
  | Collapse
  | Mark
  | Unmark
  | Hover
  | Unhover
  | MakeEditable
  | MakeStatic
  | Frame
  | Unframe

type alias Cache = Dict SliceID SliceWrap

-- | recursively updating the editor model
nodeUpdate: EditorAction -> Cache -> Set SliceID -> Node -> Result String Node
nodeUpdate action cache changed node =
  if String.startsWith node.id action.target then
    if node.id == action.target then
      case action.action of
        Mark ->
          Ok { node | marked = True }
        Unmark ->
          Ok { node | marked = False }
        Hover ->
          Ok { node | hovered = True }
        Unhover ->
          Ok { node | hovered = False }
        Expand ->
          expandNode cache node changed
        Collapse ->
          collapseNode node
        MakeEditable ->
          Ok { node | editable = True }
        MakeStatic ->
          Ok { node | editable = False }
        Frame ->
          Ok { node | framed = True }
        Unframe ->
          Ok { node | framed = False }
    else
      propagateUpdate action cache changed node
  else
    Ok node

propagateUpdate : EditorAction -> Cache -> Set SliceID -> Node -> Result String Node
propagateUpdate action cache changed node =
  case node.children of
    Collapsed ->
      Ok node
    Expanded cs ->
      case combineResults (List.map (nodeUpdate action cache changed) cs) of
        Ok newNodes ->
          Ok { node | children = Expanded newNodes }
        Err errs    ->
          Err (String.concat (List.intersperse "," errs))

collapseNode : Node -> Result String Node
collapseNode node =
  Ok { node | children = Collapsed }

-- | create the children of a node
expandNode : Cache -> Node -> Set SliceID -> Result String Node
expandNode cache node changed =
  if node.children /= Collapsed then
    Ok node
  else
    case node.content of
      SliceNode sw ->
        tupleCombineResults
          ( fetchMap cache sw.occurences
          , fetchMap cache (extractDependencies sw.slice)
          )
        |> Result.map (\(occs, deps) ->
          { node | children = Expanded
            [ { defaultNode |
                id = node.id ++ "occ"
                , content = Occurences occs
              }
            , { defaultNode |
                id = node.id ++ "dep"
                , content = Dependencies deps
              }
            ]
          })
        |> Result.map (updateChanged changed)
      Occurences occs ->
        { node | children = Expanded
            (List.map
              (\sw ->
                { defaultNode |
                    id = node.id ++ sw.id
                    , content = SliceNode sw
                }
              )
              occs)
        }
        |> Ok
        |> Result.map (updateChanged changed)
      Dependencies deps ->
        { node | children = Expanded
            (List.map
              (\sw ->
                { defaultNode |
                    id = node.id ++ sw.id
                    , content = SliceNode sw
                }
              )
              deps)
        }
        |> Ok
        |> Result.map (updateChanged changed)

-- Load slicewrap from cache
fetch : Cache -> SliceID -> Result String SliceWrap
fetch cache sid =
  case Dict.get sid cache of
    Nothing -> Err ("Missing slice: " ++ sid)
    Just sw -> Ok sw

-- Load a bunch of slicewraps from cache
fetchMap : Cache -> List SliceID -> Result String (List SliceWrap)
fetchMap cache sids =
  List.map (fetch cache) sids
  |> combineResults
  |> Result.mapError (\x -> String.concat (List.intersperse "," x))


-- HELPERS for working with Results
tupleCombineResults : (Result String a, Result String b) -> Result String (a, b)
tupleCombineResults (x, y) =
  case (x, y) of
    (Err e1, Err e2) -> Err (e1 ++ ", " ++ e2)
    (Err e1, _     ) -> Err e1
    (_     , Err e2) -> Err e2
    (Ok  r1, Ok  r2) -> Ok (r1, r2)


combineResults : List (Result a b) -> Result (List a) (List b)
combineResults =
  List.foldl
    (\x acc ->
      case acc of
        Err errs ->
          case x of
            Err err -> Err (err :: errs)
            _       -> acc
        Ok ress ->
          case x of
            Err err -> Err [err]
            Ok res  -> Ok (ress ++ [res]) )
      (Ok [])

updateChanged : Set SliceID -> Node -> Node
updateChanged changed =
  mapNode
    (\n ->
      case n.content of
        SliceNode sw ->
          if Set.member sw.id changed then
            { n | changed = True }
          else
            { n | changed = False }
        Dependencies deps ->
          if (List.any (\{id} -> Set.member id changed) deps) then
            { n | changed = True }
          else
            { n | changed = False }
        Occurences occs ->
          if (List.any (\{id} -> Set.member id changed) occs) then
            { n | changed = True }
          else
            { n | changed = False })

-- VIEW

-- | Recursively view the editor model
viewNode : Bool -> Node -> Element Msg
viewNode dark node =
  case node.children of
    Collapsed ->
      viewCollapsedNode dark node
    Expanded children ->
      case node.content of
        SliceNode sw ->
          viewSliceNode dark sw node
        Occurences occs ->
          viewListNode dark children node
        Dependencies deps ->
          viewListNode dark children node

-- | Collapsed
viewCollapsedNode : Bool -> Node -> Element Msg
viewCollapsedNode dark { marked, id, content, changed } =
  let
    fontColor = case content of
      SliceNode _ ->
        []
      _ ->
        [ Font.color (real_black dark) ]
  in
    Element.el
      ([ Events.onClick (Editor {target = id, action = Expand})
       , Element.pointer
       , Element.mouseOver [ Background.color (grey dark) ]
       ]
      ++ (if marked then [ Background.color (grey dark) ] else [])
      ++ fontColor)
      (viewTeaser dark content changed)

viewTeaser : Bool -> NodeContent -> Bool -> Element Msg
viewTeaser dark content changed =
  Element.row
    [ Element.spacing 0
    , Element.padding 0
    ]
    [ Element.el
        [ Font.color
            (if changed then (signal_color dark) else (real_black dark))
        ]
        (Element.text "⮟ ")
    , case content of
        SliceNode {tagline} ->
          EditorField.inlineSH tagline
        Occurences occs ->
          case String.fromInt (List.length occs) of
            l ->
              Element.text
                ("show " ++ l ++ " occurences")
        Dependencies deps ->
          case String.fromInt (List.length deps) of
            l ->
              Element.text
                ("show " ++ l ++ " dependencies")
    ]

-- Expanded - Slice
viewSliceNode : Bool -> SliceWrap -> Node -> Element Msg
viewSliceNode dark sw { hovered, marked, id, children, editable, framed, changed } =
  case children of
    Expanded (occs :: deps :: _) ->
      let
        (smallOccs, smallDeps) =
          if hovered || editable then
            ( if occs.children == Collapsed then viewIfNotEmpty occs else []
            , if deps.children == Collapsed then viewIfNotEmpty deps else []
            )
          else
            ( [], [] )

        (bigOccs, bigDeps) =
          ( if occs.children /= Collapsed then viewIfNotEmpty occs else []
          , if deps.children /= Collapsed then viewIfNotEmpty deps else []
          )

        viewIfNotEmpty n =
          if isEmptyNode n then [] else [ viewNode dark n ]

        debugInfo = []
          {-[ Element.row
              [ Element.spacing 8 ] (List.map Element.text sw.names)
          , Element.row
              [ Element.spacing 8 ] (List.map Element.text sw.signatures)
          ]-}

      in
        Element.el
          (frameIf dark framed)
          (viewCollapsable dark
            id
            (Element.column
              [ Element.spacing 8
              ]
              ( bigOccs ++
                [ Element.column
                    ((Element.spacing 8) :: (nodeAttributes dark hovered marked id))
                    ( smallOccs ++ [(viewSlice dark sw editable changed id)] ++ smallDeps )
                ]
                ++ bigDeps
                ++ debugInfo)))

    _ -> Element.text "Faulty SliceNode: Expanded but no children"

isEmptyNode : Node -> Bool
isEmptyNode { content } =
  case content of
    Occurences   [] -> True
    Dependencies [] -> True
    _               -> False

nodeAttributes : Bool -> Bool -> Bool -> SliceID -> List (Element.Attribute Msg)
nodeAttributes dark hovered marked sid =
  [ Events.onMouseEnter (Editor {target = sid, action = Hover})
  , Events.onMouseLeave (Editor {target = sid, action = Unhover})
  ] ++ (if marked || hovered then [ Background.color (grey dark) ] else [])

viewSlice : Bool -> SliceWrap -> Bool -> Bool -> String -> Element Msg
viewSlice dark sw editable changed nodeId =
  let
    renderedFragment = renderFragment sw.slice
    highlightDict =
      List.map
        (Tuple.mapSecond
          (\mid ->
            [ HtmlEvents.onMouseEnter
                (Editor {target = nodeId ++ "dep" ++ mid, action = Mark})
            , HtmlEvents.onMouseLeave
                (Editor {target = nodeId ++ "dep" ++ mid, action = Unmark})
            , HtmlAttributes.class "reference"
            ]
          )
        )
        (extractReferences sw.slice)
      |> Dict.fromList
    dirtyAttribs =
      if changed then
        [ Border.widthEach { edges | left = 1 }
        , Border.color (signal_color dark)
        ]
      else
        []
  in
    if editable then
      Element.row
        dirtyAttribs
        [ Element.el
            [ Border.width 1
            , Border.color (grey dark)
            ]
            (EditorField.editorField
              renderedFragment
              (\txt -> Main (TextEdit txt sw))
              highlightDict)
        , Element.el
            [ Events.onClick (Editor {target = nodeId, action = MakeStatic})
            , Element.pointer
            , Element.mouseOver [ Background.color (black dark) ]
            , Font.size 32
            , Element.height Element.fill
            , Element.width Element.fill
            , Element.spaceEvenly
            , Element.paddingEach {edges | left = 5}
            ]
            (Element.text "✓")
        ]
    else
      Element.el
        ([ Events.onClick (Editor {target = nodeId, action = MakeEditable})
        ] ++ dirtyAttribs)
        (EditorField.syntaxHighlight renderedFragment highlightDict)

-- | Expanded - Occurences/Dependencies

viewListNode : Bool -> List Node -> Node -> Element Msg
viewListNode dark nodes { hovered, marked, framed, id } =
  Element.el
    (frameIf dark framed)
    (viewCollapsable dark
      id
      (Element.column
        [ Element.spacing 16 ]
        (List.map (viewNode dark) nodes)))

-- | Common helpers

viewCollapsable : Bool -> SliceID -> Element Msg -> Element Msg
viewCollapsable dark sid content =
  Element.row
    [ Element.spacing 5 ]
    [ (Element.column
        [ Element.height Element.fill
        , Events.onClick (Editor {target = sid, action = Collapse})
        , Events.onMouseEnter (Editor {target = sid, action = Frame})
        , Events.onMouseLeave (Editor {target = sid, action = Unframe})
        , Element.pointer
        , Font.color (real_black dark)
        , Element.mouseOver [ Background.color (grey dark) ]
        ]
        [ {- Element.el
            [ Element.alignTop ]
            ( Element.text "⮟" )
        ,-} Element.el
            [ Element.centerX
            , Element.width (Element.px 1)
            , Element.height Element.fill
            , Border.widthEach { bottom = 0, left = 0, right = 1, top = 0 }
            , Border.color (real_black dark)
            ]
            Element.none
        , Element.el
            [ Element.alignBottom ]
            ( Element.text "⮝" )
        ]
      )
    , content
    ]


frameIf : Bool -> Bool -> List (Element.Attribute Msg)
frameIf dark framed =
  if framed then
     [ Border.width 1, Border.color (white dark) ]
   else
     [ Border.width 1, Border.color (black dark) ]
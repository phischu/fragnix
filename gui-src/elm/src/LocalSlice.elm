module LocalSlice exposing (..)

import Json.Encode as E
import Json.Decode as Decode
import Set exposing (Set)

import Slice exposing (..)

-- | DEFINITION
-- | Matches LocalSlice.hs as close as possible

-- | A local ID before slices have been hashed.
type LocalSliceID = LocalSliceID String

-- | A Slice with a local ID that may use slices with local IDs as well as global
-- slices with slice IDs.
type LocalSlice
  = LocalSlice
      LocalSliceID
      Language
      Fragment
      (List LocalUse)
      (List LocalInstance)

-- | A local use may refer to local slices and global slices.
type LocalUse = LocalUse (Maybe Qualification) UsedName LocalReference

type LocalReference =
    OtherSlice SliceID |
    Builtin OriginalModule |
    OtherLocalSlice LocalSliceID

type LocalInstance =
    LocalInstance InstancePart LocalInstanceID |
    GlobalInstance InstancePart InstanceID

type LocalInstanceID = LocalSliceID

-- | HELPERS

-- | Turn a SliceWrap into a LocalSlice if necessary
toLocalSlice : SliceWrap -> Maybe LocalSlice
toLocalSlice { slice, origin } =
  case origin of
    Disk ->
      Nothing
    ChangedFrom _ changes ->
      case slice of
        Slice sid lang frag uses instances ->
          LocalSlice
            (LocalSliceID sid)
            lang
            frag
            (toLocalUses
              (List.filterMap
                (\c -> case c of
                  Reference rid -> Just rid
                  _             -> Nothing)
                changes)
              uses)
            (toLocalInstances instances)

toLocalUses : List SliceID -> List Use -> List LocalUse
toLocalUses locals uses =
  List.map (toLocalUse locals) uses

toLocalUse : List SliceID -> Use -> LocalUse
toLocalUse locals (Use qual usedName ref) =
  LocalUse
    qual
    usedName
    (case ref of
      OtherSlice sid ->
        if List.member sid locals then
          OtherLocalSlice sid
        else
          OtherSlice sid
      Builtin mod ->
        Builtin mod)

-- TODO: What do instances mean? / How does their dirtying propagate?
toLocalInstances : List Instance -> List LocalInstance
toLocalInstances instances =
  List.map (\(Instance part sid) -> (GlobalInstance part sid)) instances

-- | ENCODERS
encodeLocalSlice : LocalSlice -> E.Value
encodeLocalSlice (LocalSlice sid lang frag uses instances) =
  E.object
    [ ("localSliceID", encodeLocalSliceID sid)
    , ("language", encodeLanguage lang)
    , ("fragment", encodeFragment frag)
    , ("localUses", E.list encodeLocalUse uses)
    , ("localInstances", E.list encodeLocalInstance instances)
    ]

encodeLocalSliceID : LocalSliceID -> E.Value
encodeLocalSliceID (LocalSliceID sid) = E.string sid

encodeLanguage : Language -> E.Value
encodeLanguage (Language ghcexts) =
  E.object
    [("extensions", E.list E.string ghcexts)]

encodeFragment : Fragment -> E.Value
encodeFragment (Fragment lines) =
  E.list E.string lines

encodeLocalUse : LocalUse -> E.Value
encodeLocalUse (LocalUse qual usedName localRef) =
  E.object
    [ ("qualification", encodeQualification qual)
    , ("usedName", encodeUsedName usedName)
    , ("localReference", encodeLocalReference localRef)
    ]

encodeQualification : Maybe Qualification -> E.Value
encodeQualification qual =
  case qual of
    Nothing -> E.null
    Just s  -> E.string s

encodeUsedName : UsedName -> E.Value
encodeUsedName uname =
  case uname of
    ValueName n ->
      E.object [("valueName", encodeName n)]
    TypeName n ->
      E.object [("typeName", encodeName n)]
    ConstructorName typeN n ->
      E.object
        [ ("constructorTypeName", encodeName typeN)
        , ("constructorName", encodeName n)
        ]

encodeName : Name -> E.Value
encodeName n =
  case n of
    Identifier i ->
      E.object [("identifier", E.string i)]
    Operator o ->
      E.object [("operator", E.string o)]

encodeLocalReference : LocalReference -> E.Value
encodeLocalReference ref =
  case ref of
    OtherSlice sid ->
      E.object [("otherSlice", E.string sid)]
    Builtin originalModule ->
      E.object [("builtinModule", E.string originalModule)]
    OtherLocalSlice sid ->
      E.object [("otherLocalSlice", E.string sid)]

encodeLocalInstance : LocalInstance -> E.Value
encodeLocalInstance inst =
  case inst of
    LocalInstance iPart localInstId ->
      E.object
        [ ("instancePart", encodeInstancePart iPart)
        , ("localInstanceID", encodeLocalSliceID localInstId)
        ]
    GlobalInstance iPart globalInstId ->
      E.object
        [ ("instancePart", encodeInstancePart iPart)
        , ("globalInstanceID", E.string globalInstId)
        ]

encodeInstancePart : InstancePart -> E.Value
encodeInstancePart part =
  case part of
    OfThisClass ->
      E.string "OfThisClass"
    OfThisClassForUnknownType ->
      E.string "OfThisClassForUnknownType"
    ForThisType ->
      E.string "ForThisType"
    ForThisTypeOfUnknownClass ->
      E.string "ForThisTypeOfUnknownClass"
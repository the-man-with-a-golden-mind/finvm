module FinVM.Input.Schema
  ( InputFieldSpec
  , decodeSchema
  , validateInputValues
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Set as Set
import Data.Argonaut.Core as Json
import Foreign.Object (Object)
import Foreign.Object as Object
import FinVM.Error (VMError(..), ErrorCode(..))
import FinVM.Type (VMType(..))
import FinVM.Value (Value(..))

type InputFieldSpec =
  { name :: String
  , type_ :: VMType
  , required :: Boolean
  }

decodeSchema :: Object Json.Json -> Either String (Array InputFieldSpec)
decodeSchema inputsObj = case Object.lookup "schema" inputsObj of
  Nothing -> pure []
  Just json -> do
    arr <- asArray "inputs.schema" json
    traverse decodeFieldSpec arr

decodeFieldSpec :: Json.Json -> Either String InputFieldSpec
decodeFieldSpec json = do
  obj <- asObject "schema entry" json
  name <- requiredString "name" obj
  typeName <- requiredString "type" obj
  required <- case Object.lookup "required" obj of
    Nothing -> pure true
    Just j -> asBool "required" j
  type_ <- parseTypeName typeName
  pure { name, type_: type_, required }

parseTypeName :: String -> Either String VMType
parseTypeName name = case name of
  "Unit" -> pure TUnit
  "Bool" -> pure TBool
  "Int" -> pure TInt
  "String" -> pure TString
  "Bytes" -> pure TBytes
  "Any" -> pure TAny
  other -> Left ("Unknown input type: " <> other)

validateInputValues
  :: Array InputFieldSpec
  -> Map String Value
  -> Either VMError (Map String Value)
validateInputValues schema values = do
  let schemaNames = map (\f -> f.name) schema
      valueKeys = Set.toUnfoldable (Map.keys values) :: Array String
      extraKeys = Array.filter (\k -> not (Array.elem k schemaNames)) valueKeys
  result <- go schema Map.empty
  if Array.null extraKeys
    then pure result
    else Left $ VMError InputValidation ("Unknown input fields: " <> show extraKeys)
  where
    go [] acc = pure acc
    go fields acc = case Array.uncons fields of
      Nothing -> pure acc
      Just { head: field, tail: rest } ->
        case Map.lookup field.name values of
          Nothing ->
            if field.required
              then Left $ VMError MissingInput ("Required input missing: " <> field.name)
              else go rest acc
          Just value ->
            case checkType field.type_ value of
              Left err -> Left $ VMError InputValidation ("Input '" <> field.name <> "': " <> err)
              Right _ -> go rest (Map.insert field.name value acc)

checkType :: VMType -> Value -> Either String Unit
checkType expected value = case expected, value of
  TUnit, VUnit -> Right unit
  TBool, VBool _ -> Right unit
  TInt, VInt _ -> Right unit
  TString, VString _ -> Right unit
  TBytes, VBytes _ -> Right unit
  TAny, _ -> Right unit
  _, _ -> Left ("expected " <> showTypeName expected <> ", got " <> showValueKind value)

showTypeName :: VMType -> String
showTypeName = case _ of
  TUnit -> "Unit"
  TBool -> "Bool"
  TInt -> "Int"
  TString -> "String"
  TBytes -> "Bytes"
  TAny -> "Any"
  _ -> "complex"

showValueKind :: Value -> String
showValueKind = case _ of
  VUnit -> "Unit"
  VBool _ -> "Bool"
  VInt _ -> "Int"
  VString _ -> "String"
  VBytes _ -> "Bytes"
  _ -> "other"

asArray :: String -> Json.Json -> Either String (Array Json.Json)
asArray label value = case Json.toArray value of
  Just arr -> pure arr
  Nothing -> Left ("Expected array at " <> label)

asObject :: String -> Json.Json -> Either String (Object Json.Json)
asObject label value = case Json.toObject value of
  Just obj -> pure obj
  Nothing -> Left ("Expected object at " <> label)

asBool :: String -> Json.Json -> Either String Boolean
asBool label value = case Json.toBoolean value of
  Just b -> pure b
  Nothing -> Left ("Expected boolean at " <> label)

requiredString :: String -> Object Json.Json -> Either String String
requiredString key obj = case Object.lookup key obj of
  Just j -> case Json.toString j of
    Just s -> pure s
    Nothing -> Left ("Expected string at " <> key)
  Nothing -> Left ("Missing field: " <> key)

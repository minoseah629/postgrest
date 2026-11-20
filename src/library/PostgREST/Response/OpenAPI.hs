{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : PostgREST.OpenAPI
-- Description : Generates the OpenAPI output
module PostgREST.Response.OpenAPI (encode) where

import Control.Arrow ((&&&))
import Control.Lens (at, over, (%~), (.~), (?~))
import Data.HashMap.Strict.InsOrd (InsOrdHashMap, fromList)
import Data.Maybe (fromJust)
import Data.String (IsString (..))
import Data.Swagger
import Network.URI (URI (..), URIAuth (..))
import Protolude hiding (Proxy, get)

import Data.Aeson qualified as JSON
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.HashMap.Strict qualified as HM
import Data.HashMap.Strict.InsOrd qualified as InsOrd
import Data.HashSet.InsOrd qualified as Set
import Data.Text qualified as T

import PostgREST.Catalog.Identifiers (QualifiedIdentifier (..))
import PostgREST.Catalog.Relationship
  ( Cardinality (..)
  , Relationship (..)
  , RelationshipsMap
  )
import PostgREST.Catalog.Routine
  ( FuncVolatility (..)
  , Routine (..)
  , RoutineParam (..)
  )
import PostgREST.Catalog.Table
  ( Column (..)
  , Table (..)
  , TablesMap
  , tableColumnsList
  )
import PostgREST.Config
  ( AppConfig (..)
  , Proxy (..)
  , isMalformedProxyUri
  , toURI
  )
import PostgREST.MediaType
import PostgREST.Network (escapeHostName)
import PostgREST.SchemaCache (SchemaCache (..))

encode :: (Text, Text) -> AppConfig -> SchemaCache -> TablesMap -> HM.HashMap k [Routine] -> Maybe Text -> LBS.ByteString
encode versions conf sCache tables procs schemaDescription =
  JSON.encode $
    postgrestSpec
      versions
      (dbRelationships sCache)
      (concat $ HM.elems procs)
      (snd <$> HM.toList tables)
      (proxyUri conf)
      schemaDescription
      (configOpenApiSecurityActive conf)
      (configDbMaxRows conf)
      (configOpenApiRateLimit conf)

-- | Name of the shared schema describing PostgREST error bodies.
errorSchemaName :: Text
errorSchemaName = "PostgrestError"

makeErrorSchema :: Schema
makeErrorSchema =
  (mempty :: Schema)
    & description ?~ "Error body returned by PostgREST"
    & type_ ?~ SwaggerObject
    & properties
      .~ fromList
        [ ("code", errorTextProperty),
          ("message", errorTextProperty),
          ("details", errorTextProperty),
          ("hint", errorTextProperty)
        ]
  where
    errorTextProperty =
      Inline $
        (mempty :: Schema)
          & type_ ?~ SwaggerString
          & format ?~ "text"
          & maxLength ?~ 2000

makeErrorResponse :: Text -> Referenced Response
makeErrorResponse d =
  Inline $
    (mempty :: Response)
      & description .~ d
      & schema ?~ Ref (Reference errorSchemaName)

-- | Documents the error responses PostgREST can always return.
withErrorResponses :: Operation -> Operation
withErrorResponses op =
  op
    & at 400 ?~ makeErrorResponse "Bad request"
    & at 401 ?~ makeErrorResponse "Missing, invalid or expired JWT"
    & at 500 ?~ makeErrorResponse "Internal server error"

-- | Documents a gateway-enforced rate limit (PostgREST itself does not enforce it):
-- a 429 response on every operation plus rate-limit headers on 2xx/4xx responses.
withRateLimit :: Maybe Integer -> Swagger -> Swagger
withRateLimit Nothing = identity
withRateLimit (Just limit) = over (paths . traverse) onPathItem
  where
    onPathItem pathItem =
      pathItem
        & get %~ fmap onOperation
        & post %~ fmap onOperation
        & patch %~ fmap onOperation
        & delete %~ fmap onOperation
    onOperation op =
      (op & at 429 ?~ makeErrorResponse ("Too many requests, limit is " <> show limit <> " per second"))
        & responses %~ (\rs -> rs {_responsesResponses = InsOrd.mapWithKey addHeaders (_responsesResponses rs)})
    addHeaders code (Inline r)
      | code `div` 100 `elem` [2, 4] =
          Inline $ r & headers %~ (InsOrd.fromList (limitHeaders code) <>)
    addHeaders _ other = other
    limitHeaders code =
      ("X-RateLimit-Limit", intHeader ("Requests per second allowed by the gateway (" <> show limit <> ")"))
        : [("Retry-After", intHeader "Seconds to wait before retrying") | code == (429 :: Int)]
    intHeader d =
      Header (Just d) $
        mempty
          & type_ ?~ SwaggerInteger
          & format ?~ "int32"
          & minimum_ ?~ 0
          & maximum_ ?~ 2147483647

-- | Makes a name usable as an operationId (ASCII letters, digits and underscore).
toOperationId :: Text -> Text
toOperationId = T.map (\c -> if c `elem` allowedChars then c else '_')
  where
    allowedChars = ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] ++ "_"

-- | Patterns describing PostgREST's own query/header grammar.
rowFilterPattern :: Text
rowFilterPattern = "^(not\\.)?(eq|neq|gt|gte|lt|lte|like|ilike|match|imatch|in|is|isdistinct|cs|cd|ov|sl|sr|nxl|nxr|adj|fts|plfts|phfts|wfts)(\\([a-z]+\\))?\\..{0,200}$"

selectPattern :: Text
selectPattern = "^[A-Za-z0-9_.,:()*>!\\-]{1,500}$"

orderPattern :: Text
orderPattern = "^[A-Za-z0-9_.,]{1,200}$"

onConflictPattern :: Text
onConflictPattern = "^[A-Za-z0-9_,]{1,200}$"

numberPattern :: Text
numberPattern = "^[0-9]{1,9}$"

rangePattern :: Text
rangePattern = "^[0-9]*-[0-9]*$"

preferPattern :: Text
preferPattern = "^[A-Za-z0-9=,;_\\- ]{1,200}$"

makeMimeList :: [MediaType] -> MimeList
makeMimeList cs = MimeList $ fmap (fromString . BS.unpack . toMime) cs

toSwaggerType :: Text -> Maybe (SwaggerType t)
toSwaggerType "character varying" = Just SwaggerString
toSwaggerType "character" = Just SwaggerString
toSwaggerType "text" = Just SwaggerString
toSwaggerType "boolean" = Just SwaggerBoolean
toSwaggerType "smallint" = Just SwaggerInteger
toSwaggerType "integer" = Just SwaggerInteger
toSwaggerType "bigint" = Just SwaggerInteger
toSwaggerType "numeric" = Just SwaggerNumber
toSwaggerType "real" = Just SwaggerNumber
toSwaggerType "double precision" = Just SwaggerNumber
toSwaggerType "json" = Nothing
toSwaggerType "jsonb" = Nothing
toSwaggerType colType = case T.takeEnd 2 colType of
  "[]" -> Just SwaggerArray
  _ -> Just SwaggerString

toSwaggerFormat :: Text -> Maybe Text
toSwaggerFormat "smallint" = Just "int32"
toSwaggerFormat "integer" = Just "int32"
toSwaggerFormat "bigint" = Just "int64"
toSwaggerFormat colType = Just colType

typeFromArray :: Text -> Text
typeFromArray = T.dropEnd 2

toSwaggerTypeFromArray :: Text -> Maybe (SwaggerType t)
toSwaggerTypeFromArray arrType = toSwaggerType $ typeFromArray arrType

makePropertyItems :: Text -> Maybe (Referenced Schema)
makePropertyItems arrType = case toSwaggerType arrType of
  Just SwaggerArray -> Just $ Inline (mempty & type_ .~ toSwaggerTypeFromArray arrType)
  _ -> Nothing

parseDefault :: Text -> Text -> Text
parseDefault colType colDefault =
  case toSwaggerType colType of
    Just SwaggerString -> wrapInQuotations $ case T.stripSuffix ("::" <> colType) colDefault of
      Just def -> T.dropAround (== '\'') def
      Nothing -> colDefault
    _ -> colDefault
  where
    wrapInQuotations text = "\"" <> text <> "\""

makeTableDef :: RelationshipsMap -> Table -> (Text, Schema)
makeTableDef rels t =
  let tn = tableName t
  in  ( tn,
        (mempty :: Schema)
          & description .~ tableDescription t
          & type_ ?~ SwaggerObject
          & properties .~ fromList (makeProperty t rels <$> tableColumnsList t)
          & required .~ fmap colName (filter (not . colNullable) $ tableColumnsList t)
      )

makeProperty :: Table -> RelationshipsMap -> Column -> (Text, Referenced Schema)
makeProperty tbl rels col = (colName col, Inline s)
  where
    e = if null $ colEnum col then Nothing else JSON.decode $ JSON.encode $ colEnum col
    fk :: Maybe Text
    fk =
      let
        searchedRels = fromMaybe mempty $ HM.lookup (QualifiedIdentifier (tableSchema tbl) (tableName tbl), tableSchema tbl) rels
        -- Sorts the relationship list to get tables first
        relsSortedByIsView = sortOn relFTableIsView [r | r@Relationship{} <- searchedRels]
        -- Finds the relationship that has a single column foreign key
        rel =
          find
            ( \case
                Relationship{relCardinality = (M2O _ relColumns)} -> [colName col] == (fst <$> relColumns)
                Relationship{relCardinality = (O2O _ relColumns False)} -> [colName col] == (fst <$> relColumns)
                _ -> False
            )
            relsSortedByIsView
        fCol = (headMay . (\r -> snd <$> relColumns (relCardinality r)) =<< rel)
        fTbl = qiName . relForeignTable <$> rel
        fTblCol = (,) <$> fTbl <*> fCol
      in
        (\(a, b) -> T.intercalate "" ["This is a Foreign Key to `", a, ".", b, "`.<fk table='", a, "' column='", b, "'/>"]) <$> fTblCol
    -- a default like gen_random_uuid() is a SQL expression, not a valid example for format "uuid"
    isUuidFunctionDefault :: Bool
    isUuidFunctionDefault = colType col == "uuid" && maybe False (T.isInfixOf "(") (colDefault col)
    pk :: Bool
    pk = colName col `elem` tablePKCols tbl
    n =
      catMaybes
        [ Just "Note:",
          if pk then Just "This is a Primary Key.<pk/>" else Nothing,
          fk
        ]
    d =
      if length n > 1 then
        Just $ T.append (maybe "" (`T.append` "\n\n") $ colDescription col) (T.intercalate "\n" n)
      else
        colDescription col
    s =
      (mempty :: Schema)
        & default_ .~ (if isUuidFunctionDefault then Nothing else JSON.decode . toUtf8Lazy . parseDefault (colType col) =<< colDefault col)
        & description .~ d
        & enum_ .~ e
        & format .~ toSwaggerFormat (colType col)
        -- a uuid always has the canonical 36 character text form
        & maxLength .~ ((fromIntegral <$> colMaxLen col) <|> (if colType col == "uuid" then Just 36 else Nothing))
        & type_ .~ toSwaggerType (colType col)
        & items .~ (SwaggerItemsObject <$> makePropertyItems (colType col))

makeProcSchema :: Routine -> Schema
makeProcSchema pd =
  (mempty :: Schema)
    & description .~ pdDescription pd
    & type_ ?~ SwaggerObject
    & properties .~ fromList (fmap makeProcProperty (pdParams pd))
    & required .~ fmap ppName (filter ppReq (pdParams pd))

makeProcProperty :: RoutineParam -> (Text, Referenced Schema)
makeProcProperty (RoutineParam n t _ _ _) = (n, Inline s)
  where
    s =
      (mempty :: Schema)
        & type_ .~ toSwaggerType t
        & items .~ (SwaggerItemsObject <$> makePropertyItems t)
        & format .~ toSwaggerFormat t

makePreferParam :: [Text] -> Param
makePreferParam ts =
  (mempty :: Param)
    & name .~ "Prefer"
    & description ?~ "Preference"
    & required ?~ False
    & schema
      .~ ParamOther
        ( (mempty :: ParamOtherSchema)
            & in_ .~ ParamHeader
            & type_ ?~ SwaggerString
            & enum_ .~ (if null enu then Nothing else JSON.decode (JSON.encode enu))
            & pattern .~ (if null enu then Just preferPattern else Nothing)
            & maxLength .~ (if null enu then Just 200 else Nothing)
        )
  where
    enu = foldl (<>) [] (val <$> ts)
    val :: Text -> [Text]
    val = \case
      "count" -> ["count=none"]
      "return" -> ["return=representation", "return=minimal", "return=none"]
      "resolution" -> ["resolution=ignore-duplicates", "resolution=merge-duplicates"]
      _ -> []

makeProcGetParam :: RoutineParam -> Referenced Param
makeProcGetParam (RoutineParam n t _ r v) =
  Inline $
    (mempty :: Param)
      & name .~ n
      & required ?~ r
      & schema .~ ParamOther fullSchema
  where
    fullSchema = if v then schemaMulti else schemaNotMulti
    baseSchema =
      (mempty :: ParamOtherSchema)
        & in_ .~ ParamQuery
    schemaNotMulti =
      baseSchema
        & format .~ toSwaggerFormat t
        & type_ ?~ toParamType (toSwaggerType t)
    schemaMulti =
      baseSchema
        & type_ ?~ fromMaybe SwaggerString (toSwaggerType t)
        & items
          ?~ SwaggerItemsPrimitive
            (Just CollectionMulti)
            ( (mempty :: ParamSchema x)
                & type_ .~ toSwaggerTypeFromArray t
                & format .~ toSwaggerFormat (typeFromArray t)
            )
    toParamType paramType = case paramType of
      -- Array uses {} in query params
      Just SwaggerArray -> SwaggerString
      -- Type must be specified in query params
      Nothing -> SwaggerString
      _ -> fromJust paramType

makeProcGetParams :: [RoutineParam] -> [Referenced Param]
makeProcGetParams = fmap makeProcGetParam

makeProcPostParams :: Routine -> [Referenced Param]
makeProcPostParams pd =
  [ Inline $
      (mempty :: Param)
        & name .~ "args"
        & required ?~ True
        & schema .~ ParamBody (Inline $ makeProcSchema pd),
    Ref $ Reference "preferParams"
  ]

makeParamDefs :: [Table] -> [(Text, Param)]
makeParamDefs ti =
  -- TODO: create Prefer for each method (GET, PATCH, etc.)
  [ ("preferParams", makePreferParam ["params"]),
    ("preferReturn", makePreferParam ["return"]),
    ("preferCount", makePreferParam ["count"]),
    ("preferPost", makePreferParam ["return", "resolution"]),
    ( "select",
      (mempty :: Param)
        & name .~ "select"
        & description ?~ "Filtering Columns"
        & required ?~ False
        & schema
          .~ ParamOther
            ( (mempty :: ParamOtherSchema)
                & in_ .~ ParamQuery
                & type_ ?~ SwaggerString
                & pattern ?~ selectPattern
                & maxLength ?~ 500
            )
    ),
    ( "on_conflict",
      (mempty :: Param)
        & name .~ "on_conflict"
        & description ?~ "On Conflict"
        & required ?~ False
        & schema
          .~ ParamOther
            ( (mempty :: ParamOtherSchema)
                & in_ .~ ParamQuery
                & type_ ?~ SwaggerString
                & pattern ?~ onConflictPattern
                & maxLength ?~ 200
            )
    ),
    ( "order",
      (mempty :: Param)
        & name .~ "order"
        & description ?~ "Ordering"
        & required ?~ False
        & schema
          .~ ParamOther
            ( (mempty :: ParamOtherSchema)
                & in_ .~ ParamQuery
                & type_ ?~ SwaggerString
                & pattern ?~ orderPattern
                & maxLength ?~ 200
            )
    ),
    ( "range",
      (mempty :: Param)
        & name .~ "Range"
        & description ?~ "Limiting and Pagination"
        & required ?~ False
        & schema
          .~ ParamOther
            ( (mempty :: ParamOtherSchema)
                & in_ .~ ParamHeader
                & type_ ?~ SwaggerString
                & pattern ?~ rangePattern
                & maxLength ?~ 200
            )
    ),
    ( "rangeUnit",
      (mempty :: Param)
        & name .~ "Range-Unit"
        & description ?~ "Limiting and Pagination"
        & required ?~ False
        & schema
          .~ ParamOther
            ( (mempty :: ParamOtherSchema)
                & in_ .~ ParamHeader
                & type_ ?~ SwaggerString
                & default_ .~ JSON.decode "\"items\""
                & enum_ .~ JSON.decode "[\"items\"]"
            )
    ),
    ( "offset",
      (mempty :: Param)
        & name .~ "offset"
        & description ?~ "Limiting and Pagination"
        & required ?~ False
        & schema
          .~ ParamOther
            ( (mempty :: ParamOtherSchema)
                & in_ .~ ParamQuery
                & type_ ?~ SwaggerString
                & pattern ?~ numberPattern
                & maxLength ?~ 200
            )
    ),
    ( "limit",
      (mempty :: Param)
        & name .~ "limit"
        & description ?~ "Limiting and Pagination"
        & required ?~ False
        & schema
          .~ ParamOther
            ( (mempty :: ParamOtherSchema)
                & in_ .~ ParamQuery
                & type_ ?~ SwaggerString
                & pattern ?~ numberPattern
                & maxLength ?~ 200
            )
    )
  ]
    <> concat
      [ makeObjectBody (tableName t) : makeRowFilters (tableName t) (tableColumnsList t)
      | t <- ti
      ]

makeObjectBody :: Text -> (Text, Param)
makeObjectBody tn =
  ( "body." <> tn,
    (mempty :: Param)
      & name .~ tn
      & description ?~ tn
      & required ?~ False
      & schema .~ ParamBody (Ref (Reference tn))
  )

makeRowFilter :: Text -> Column -> (Text, Param)
makeRowFilter tn c =
  ( T.intercalate "." ["rowFilter", tn, colName c],
    (mempty :: Param)
      & name .~ colName c
      & description .~ (colDescription c <|> Just ("Filter on " <> colName c <> " using PostgREST operator syntax, e.g. eq.value"))
      & required ?~ False
      & schema
        .~ ParamOther
          ( (mempty :: ParamOtherSchema)
              & in_ .~ ParamQuery
              & type_ ?~ SwaggerString
              & pattern ?~ rowFilterPattern
              & maxLength ?~ 256
          )
  )

makeRowFilters :: Text -> [Column] -> [(Text, Param)]
makeRowFilters tn = fmap (makeRowFilter tn)

makePathItem :: Maybe Integer -> Table -> (FilePath, PathItem)
makePathItem maxRows t = ("/" ++ T.unpack tn, p $ tableInsertable t || tableUpdatable t || tableDeletable t)
  where
    -- Use first line of table description as summary; rest as description (if present)
    -- We strip leading newlines from description so that users can include a blank line between summary and description
    (tSum, tDesc) =
      fmap fst &&& fmap (T.dropWhile (== '\n') . snd) $
        T.breakOn "\n" <$> tableDescription t
    tOp =
      withErrorResponses $
        (mempty :: Operation)
          & tags .~ Set.fromList [tn]
          & summary .~ tSum
    -- the table description (when present) applies to every method, otherwise a generic one is used
    opDescription fallback = mfilter (/= "") tDesc <|> Just fallback
    getOp =
      tOp
        & operationId ?~ toOperationId ("get_" <> tn)
        & description .~ opDescription ("Read rows from " <> tn)
        & parameters .~ fmap ref (rs <> ["select", "order", "range", "rangeUnit", "offset", "limit", "preferCount"])
        & at 206 ?~ "Partial Content"
        & at 200
          ?~ Inline
            ( (mempty :: Response)
                & description .~ "OK"
                & schema
                  ?~ Inline
                    ( mempty
                        & type_ ?~ SwaggerArray
                        & maxItems .~ maxRows
                        & items ?~ SwaggerItemsObject (Ref $ Reference $ tableName t)
                    )
            )
    postOp =
      tOp
        & operationId ?~ toOperationId ("post_" <> tn)
        & description .~ opDescription ("Insert rows into " <> tn)
        & parameters .~ fmap ref ["body." <> tn, "select", "preferPost"]
        & at 201 ?~ "Created"
    patchOp =
      tOp
        & operationId ?~ toOperationId ("patch_" <> tn)
        & description .~ opDescription ("Update rows in " <> tn)
        & parameters .~ fmap ref (rs <> ["body." <> tn, "preferReturn"])
        & at 204 ?~ "No Content"
    deletOp =
      tOp
        & operationId ?~ toOperationId ("delete_" <> tn)
        & description .~ opDescription ("Delete rows from " <> tn)
        & parameters .~ fmap ref (rs <> ["preferReturn"])
        & at 204 ?~ "No Content"
    pr = (mempty :: PathItem) & get ?~ getOp
    pw = pr & post ?~ postOp & patch ?~ patchOp & delete ?~ deletOp
    p False = pr
    p True = pw
    tn = tableName t
    rs = [T.intercalate "." ["rowFilter", tn, colName c] | c <- tableColumnsList t]
    ref = Ref . Reference

makeProcPathItem :: Routine -> (FilePath, PathItem)
makeProcPathItem pd = ("/rpc/" ++ toS (pdName pd), pe)
  where
    -- Use first line of proc description as summary; rest as description (if present)
    -- We strip leading newlines from description so that users can include a blank line between summary and description
    (pSum, pDesc) =
      fmap fst &&& fmap (T.dropWhile (== '\n') . snd) $
        T.breakOn "\n" <$> pdDescription pd
    procOp =
      withErrorResponses $
        (mempty :: Operation)
          & summary .~ pSum
          & description .~ (mfilter (/= "") pDesc <|> Just ("Call the " <> pdName pd <> " function"))
          & tags .~ Set.fromList ["(rpc) " <> pdName pd]
          & produces ?~ makeMimeList [MTApplicationJSON, MTVndSingularJSON True, MTVndSingularJSON False]
          & at 200 ?~ "OK"
    getOp =
      procOp
        & operationId ?~ toOperationId ("rpc_get_" <> pdName pd)
        & parameters .~ makeProcGetParams (pdParams pd)
    postOp =
      procOp
        & operationId ?~ toOperationId ("rpc_post_" <> pdName pd)
        & parameters .~ makeProcPostParams pd
    pe = case pdVolatility pd of
      Volatile -> (mempty :: PathItem) & post ?~ postOp
      _ -> (mempty :: PathItem) & get ?~ getOp & post ?~ postOp

makeRootPathItem :: (FilePath, PathItem)
makeRootPathItem = ("/", p)
  where
    getOp =
      withErrorResponses $
        (mempty :: Operation)
          & tags .~ Set.fromList ["Introspection"]
          & operationId ?~ "get_root"
          & summary ?~ "OpenAPI description (this document)"
          & description ?~ "Returns the OpenAPI description of this API"
          & produces ?~ makeMimeList [MTOpenAPI, MTApplicationJSON]
          & at 200 ?~ "OK"
    pr = (mempty :: PathItem) & get ?~ getOp
    p = pr

makePathItems :: Maybe Integer -> [Routine] -> [Table] -> InsOrdHashMap FilePath PathItem
makePathItems maxRows pds ti =
  fromList $
    makeRootPathItem
      : fmap (makePathItem maxRows) ti
      ++ fmap makeProcPathItem pds

-- | Top-level tag definitions (with descriptions), sorted by name.
makeTagDefs :: [Routine] -> [Table] -> Set.InsOrdHashSet Tag
makeTagDefs pds ti =
  Set.fromList
    [ (fromString (T.unpack n) :: Tag) & description ?~ d
    | (n, d) <- sortOn fst $
        ("Introspection", "OpenAPI description of this API")
          : [(tableName t, "Operations on " <> tableName t) | t <- ti]
          ++ [("(rpc) " <> pdName pd, "Call the " <> pdName pd <> " function") | pd <- pds]
    ]

makeSecurityDefinitions :: Text -> Bool -> SecurityDefinitions
makeSecurityDefinitions secName allow
  | allow = SecurityDefinitions (fromList [(secName, SecurityScheme secSchType secSchDescription)])
  | otherwise = mempty
  where
    secSchType = SecuritySchemeApiKey (ApiKeyParams "Authorization" ApiKeyHeader)
    secSchDescription = Just "Add the token prepending \"Bearer \" (without quotes) to it"

postgrestSpec :: (Text, Text) -> RelationshipsMap -> [Routine] -> [Table] -> (Text, Text, Integer, Text) -> Maybe Text -> Bool -> Maybe Integer -> Maybe Integer -> Swagger
postgrestSpec (prettyVersion, docsVersion) rels pds ti (s, h, p, b) sd allowSecurityDef maxRows rateLimit =
  withRateLimit rateLimit $
  (mempty :: Swagger)
    & basePath ?~ T.unpack b
    & schemes ?~ [s']
    & info
      .~ ( (mempty :: Info)
             & version .~ prettyVersion
             & title .~ fromMaybe "PostgREST API" dTitle
             & description ?~ fromMaybe "This is a dynamic API generated by PostgREST" dDesc
             & contact
               ?~ ( (mempty :: Contact)
                      & name ?~ "PostgREST"
                      & url ?~ URL "https://postgrest.org"
                  )
             & license
               ?~ ( (fromString "MIT" :: License)
                      & url ?~ URL "https://github.com/PostgREST/postgrest/blob/main/LICENSE"
                  )
         )
    & externalDocs
      ?~ ( (mempty :: ExternalDocs)
             & description ?~ "PostgREST Documentation"
             & url .~ URL ("https://postgrest.org/en/" <> docsVersion <> "/references/api.html")
         )
    & host .~ h'
    & tags .~ makeTagDefs pds ti
    & definitions .~ fromList ((errorSchemaName, makeErrorSchema) : (makeTableDef rels <$> ti))
    & parameters .~ fromList (makeParamDefs ti)
    & paths .~ makePathItems maxRows pds ti
    & produces .~ makeMimeList [MTApplicationJSON, MTVndSingularJSON True, MTVndSingularJSON False, MTTextCSV]
    & consumes .~ makeMimeList [MTApplicationJSON, MTVndSingularJSON True, MTVndSingularJSON False, MTTextCSV]
    & securityDefinitions .~ makeSecurityDefinitions securityDefName allowSecurityDef
    & security .~ [SecurityRequirement (fromList [(securityDefName, [])]) | allowSecurityDef]
  where
    s' = if s == "http" then Http else Https
    h' = Just $ Host (T.unpack $ escapeHostName h) (Just (fromInteger p))
    securityDefName = "JWT"
    (dTitle, dDesc) =
      fmap fst &&& fmap (T.dropWhile (== '\n') . snd) $
        T.breakOn "\n" <$> sd

pickProxy :: Maybe Text -> Maybe Proxy
pickProxy proxy
  | isNothing proxy = Nothing
  -- should never happen
  -- since the request would have been rejected by the middleware if proxy uri
  -- is malformed
  | isMalformedProxyUri $ fromMaybe mempty proxy = Nothing
  | otherwise =
      Just
        Proxy
          { proxyScheme = scheme,
            proxyHost = host',
            proxyPort = port'',
            proxyPath = path'
          }
  where
    uri = toURI $ fromJust proxy
    scheme = T.init $ T.toLower $ T.pack $ uriScheme uri
    path URI{uriPath = ""} = "/"
    path URI{uriPath = p} = p
    path' = T.pack $ path uri
    authority = fromJust $ uriAuthority uri
    host' = T.pack $ uriRegName authority
    port' = uriPort authority
    readPort = fromMaybe 80 . readMaybe
    port'' :: Integer
    port'' = case (port', scheme) of
      ("", "http") -> 80
      ("", "https") -> 443
      _ -> readPort $ T.unpack $ T.tail $ T.pack port'

proxyUri :: AppConfig -> (Text, Text, Integer, Text)
proxyUri AppConfig{..} =
  case pickProxy $ toS <$> configOpenApiServerProxyUri of
    Just Proxy{..} ->
      (proxyScheme, proxyHost, proxyPort, proxyPath)
    Nothing ->
      ("http", configServerHost, toInteger configServerPort, "/")

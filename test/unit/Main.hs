-- | Unit tests: pure functions of the library, no database and no running server.
module Main where

import Control.Lens (at, (.~), (?~), (^?))
import Data.Aeson qualified as JSON
import Data.Aeson.Lens (key)
import Data.HashMap.Strict.InsOrd (fromList)
import Data.Swagger
import Protolude hiding (get)
import Test.Hspec

import PostgREST.Config.Proxy (isMalformedProxyUri)
import PostgREST.MediaType (MediaType (..), decodeMediaType, toMime)
import PostgREST.Response.OpenAPI (toOperationId, withRateLimit)

main :: IO ()
main = hspec $ do
  describe "PostgREST.Config.Proxy.isMalformedProxyUri" $ do
    it "accepts absolute http(s) uris" $ do
      isMalformedProxyUri "http://postgrest.org/openapi.json" `shouldBe` False
      isMalformedProxyUri "https://postgrest.org:8080/openapi.json" `shouldBe` False

    it "rejects other schemes, relative uris, queries and user info" $ do
      isMalformedProxyUri "ftp://postgrest.org" `shouldBe` True
      isMalformedProxyUri "postgrest.org" `shouldBe` True
      isMalformedProxyUri "https://postgrest.org/?a=b" `shouldBe` True
      isMalformedProxyUri "https://user@postgrest.org" `shouldBe` True

    it "rejects ports outside 1-65535" $ do
      isMalformedProxyUri "https://postgrest.org:0" `shouldBe` True
      isMalformedProxyUri "https://postgrest.org:65536" `shouldBe` True

  describe "PostgREST.MediaType" $ do
    it "decodes what it encodes for the plain media types" $
      forM_ [MTApplicationJSON, MTTextCSV, MTTextPlain, MTTextXML, MTGeoJSON, MTOpenAPI, MTOctetStream, MTAny] $ \mt ->
        decodeMediaType (toMime mt) `shouldBe` mt

    it "keeps unknown media types as MTOther" $
      decodeMediaType "foo/bar" `shouldBe` MTOther "foo/bar"

  describe "PostgREST.Response.OpenAPI.toOperationId" $ do
    it "keeps ASCII letters, digits and underscores" $
      toOperationId "get_Items_2" `shouldBe` "get_Items_2"

    it "replaces everything else with underscores" $ do
      toOperationId "get_my table" `shouldBe` "get_my_table"
      toOperationId "rpc/do-it" `shouldBe` "rpc_do_it"
      toOperationId "tabla_ñ" `shouldBe` "tabla__"

  describe "PostgREST.Response.OpenAPI.withRateLimit" $ do
    let
      op :: Operation
      op =
        (mempty :: Operation)
          & at 200 ?~ Inline (mempty :: Response)
          & at 401 ?~ Inline (mempty :: Response)
          & at 500 ?~ Inline (mempty :: Response)
      spec :: Swagger
      spec = (mempty :: Swagger) & paths .~ fromList [("/items", (mempty :: PathItem) & get ?~ op)]
      limited = JSON.toJSON (withRateLimit (Just 10) spec)
      response code = limited ^? key "paths" . key "/items" . key "get" . key "responses" . key code

    it "leaves the spec untouched when no limit is set" $
      withRateLimit Nothing spec `shouldBe` spec

    it "adds a 429 response with Retry-After and X-RateLimit-Limit" $ do
      (response "429" >>= (^? key "headers" . key "Retry-After" . key "type")) `shouldBe` Just "integer"
      (response "429" >>= (^? key "headers" . key "X-RateLimit-Limit" . key "type")) `shouldBe` Just "integer"

    it "adds X-RateLimit-Limit to 2xx and 4xx responses" $ do
      (response "200" >>= (^? key "headers" . key "X-RateLimit-Limit")) `shouldSatisfy` isJust
      (response "401" >>= (^? key "headers" . key "X-RateLimit-Limit")) `shouldSatisfy` isJust

    it "adds no rate-limit headers to 5xx responses" $
      (response "500" >>= (^? key "headers")) `shouldBe` Nothing

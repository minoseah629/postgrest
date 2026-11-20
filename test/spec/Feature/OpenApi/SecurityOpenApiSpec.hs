module Feature.OpenApi.SecurityOpenApiSpec where

import Control.Lens ((^?))
import Data.Aeson.Lens
import Data.Aeson.QQ
import Network.Wai.Test (SResponse (..))
import Protolude hiding (get)
import Test.Hspec hiding (pendingWith)
import Test.Hspec.Wai

import PostgREST.Config (AppConfig (..))
import SpecHelper

spec :: SpecWithConfig
spec withConfig = withConfig (baseCfg{configOpenApiSecurityActive = True}) $
  describe "Security active" $
    it "includes security and security definitions" $ do
      r <- simpleBody <$> get "/"

      let
        sec = r ^? key "security"
        secDef = r ^? key "securityDefinitions"

      liftIO $ do
        sec
          `shouldBe` Just
            [aesonQQ|
            [
              { "JWT": [] }
            ]
          |]

        secDef
          `shouldBe` Just
            [aesonQQ|
            {
              "JWT": {
                "description": "Add the token prepending \"Bearer \" (without quotes) to it",
                "in": "header",
                "name": "Authorization",
                "type": "apiKey"
              }
            }
          |]

rateLimitSpec :: SpecWithConfig
rateLimitSpec withConfig = withConfig (baseCfg{configOpenApiRateLimit = Just 10}) $
  describe "Rate limit documented" $ do
    it "adds a 429 response with Retry-After to operations" $ do
      r <- simpleBody <$> get "/"
      liftIO $ do
        (r ^? key "paths" . key "/items" . key "get" . key "responses" . key "429" . key "headers" . key "Retry-After" . key "type")
          `shouldBe` Just "integer"
        (r ^? key "paths" . key "/items" . key "get" . key "responses" . key "200" . key "headers" . key "X-RateLimit-Limit" . key "type")
          `shouldBe` Just "integer"
        (r ^? key "paths" . key "/items" . key "get" . key "responses" . key "401" . key "headers" . key "X-RateLimit-Limit" . key "type")
          `shouldBe` Just "integer"

    it "does not add rate-limit headers to 5xx responses" $ do
      r <- simpleBody <$> get "/"
      liftIO $
        (r ^? key "paths" . key "/items" . key "get" . key "responses" . key "500" . key "headers")
          `shouldBe` Nothing

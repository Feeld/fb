{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

module Facebook.TestUsers
  ( TestUser(..)
  , CreateTestUser(..)
  , CreateTestUserInstalled(..)
  , getTestUsers
  , disassociateTestuser
  , removeTestUser
  , createTestUser
  , makeFriendConn
  , incompleteTestUserAccessToken
  ) where

import Control.Applicative ((<$>), (<*>))
import Control.Monad (unless, mzero)
import Data.ByteString.Lazy (fromStrict)
import Data.Default
import Data.Text
import Data.Text.Encoding (encodeUtf8)
import Data.Time (UTCTime(..), Day(..))
import Data.Typeable (Typeable)
import Data.Aeson
import Data.Aeson.Types

import qualified UnliftIO.Exception as E
import qualified Control.Monad.Trans.Resource as R
import qualified Data.Aeson as A
import qualified Data.ByteString.Char8 as B

import Facebook.Auth
import Facebook.Base
import Facebook.Graph
import Facebook.Monad
import Facebook.Types
import Facebook.Pager

-- | A Facebook test user.
-- Ref: https://developers.facebook.com/docs/graph-api/reference/v2.8/app/accounts/test-users
data TestUser = TestUser
  { tuId :: UserId
  , tuAccessToken :: Maybe AccessTokenData
  , tuLoginUrl :: Maybe Text
  , tuEmail :: Maybe Text
  , tuPassword :: Maybe Text
  } deriving (Eq, Ord, Show, Read, Typeable)

instance A.FromJSON TestUser where
  parseJSON (A.Object v) =
    TestUser <$> v A..: "id" <*> v A..:? "access_token" <*> v A..:? "login_url" <*>
    v A..:? "email" <*>
    v A..:? "password"
  parseJSON _ = mzero

-- | Data type used to hold information of a new test user. This type
-- also accepts a Data.Default value.
data CreateTestUser = CreateTestUser
  { ctuInstalled :: CreateTestUserInstalled
  , ctuName :: Maybe Text
  , ctuLocale :: Maybe Text
  }

-- | Specify if the app is to be installed on the new test user.  If
-- it is, then you must tell what permissions should be given.
data CreateTestUserInstalled
  = CreateTestUserNotInstalled
  | CreateTestUserInstalled { ctuiPermissions :: [Permission]}
  | CreateTestUserFbDefault -- ^ Uses Facebook's default. It seems that this is equivalent to

-- @CreateTestUserInstalled []@, but Facebook's documentation is
-- not clear about it.
-- | Default instance for 'CreateTestUser'.
instance Default CreateTestUser where
  def = CreateTestUser def def def

-- | Default instance for 'CreateTestUserInstalled'.
instance Default CreateTestUserInstalled where
  def = CreateTestUserFbDefault

-- | Construct a query from a 'CreateTestUser'.
createTestUserQueryArgs :: CreateTestUser -> [Argument]
createTestUserQueryArgs (CreateTestUser installed name locale) =
  forInst installed ++ forField "name" name ++ forField "locale" locale
  where
    forInst (CreateTestUserInstalled p) =
      ["installed" #= True, "permissions" #= p]
    forInst CreateTestUserNotInstalled = ["installed" #= False]
    forInst CreateTestUserFbDefault = []
    forField _ Nothing = []
    forField fieldName (Just f) = [fieldName #= f]

-- | Create a new test user.
-- Ref: https://developers.facebook.com/docs/graph-api/reference/v2.8/app/accounts/test-users#publish
createTestUser
  :: (R.MonadResource m, R.MonadUnliftIO m, R.MonadThrow m)
  => CreateTestUser -- ^ How the test user should be
     -- created.
  -> AppAccessToken -- ^ Access token for your app.
  -> FacebookT Auth m TestUser
createTestUser userInfo token = do
  creds <- getCreds
  let query = ("method", "post") : createTestUserQueryArgs userInfo
  getObject ("/" <> appId creds <> "/accounts/test-users") query (Just token)

-- | Get a list of test users.
getTestUsers
  :: (R.MonadResource m, R.MonadUnliftIO m, R.MonadThrow m)
  => AppAccessToken -- ^ Access token for your app.
  -> FacebookT Auth m (Pager TestUser)
getTestUsers token = do
  creds <- getCreds
  getObject ("/" <> appId creds <> "/accounts/test-users") [] (Just token)

disassociateTestuser
  :: (R.MonadUnliftIO m, R.MonadThrow m, R.MonadResource m)
  => TestUser -> AppAccessToken -> FacebookT Auth m Bool
disassociateTestuser testUser _token = do
  creds <- getCreds
  getObjectBool
    ("/" <> (appId creds) <> "/accounts/test-users")
    [("uid", encodeUtf8 $ idCode $ tuId testUser), ("method", "delete")]
    (Just _token)

-- | Remove an existing test user.
removeTestUser
  :: (R.MonadResource m, R.MonadUnliftIO m, R.MonadThrow m)
  => TestUser -- ^ The TestUser to be removed.
  -> AppAccessToken -- ^ Access token for your app (ignored since fb 0.14.7).
  -> FacebookT Auth m Bool
removeTestUser testUser _token = do
  getObjectBool
    ("/" <> (idCode $ tuId testUser))
    [("method", "delete")]
    (Just _token)

-- | Make a friend connection between two test users.
--
-- This is how Facebook's API work: two calls must be made. The first
-- call has the format: \"\/userA_id\/friends\/userB_id\" with the
-- access token of user A as query parameter. The second call has the
-- format: \"\/userB_id\/friends\/userA_id\" with the access token of
-- user B as query parameter. The first call creates a friend request
-- and the second call accepts the friend request.
makeFriendConn
  :: (R.MonadResource m, R.MonadUnliftIO m, R.MonadThrow m)
  => TestUser -> TestUser -> FacebookT Auth m ()
makeFriendConn (TestUser {tuAccessToken = Nothing}) _ =
  E.throwIO $
  FbLibraryException
    "The test user passed on the first argument doesn't have a token. Both users must have a token."
makeFriendConn _ (TestUser {tuAccessToken = Nothing}) =
  E.throwIO $
  FbLibraryException
    "The test user passed on the second argument doesn't have a token. Both users must have a token."
makeFriendConn (TestUser {tuId = id1
                         ,tuAccessToken = (Just token1)}) (TestUser {tuId = id2
                                                                    ,tuAccessToken = (Just token2)}) = do
  let friendReq userId1 userId2 token =
        getObjectBool
          ("/" <> idCode userId1 <> "/friends/" <> idCode userId2)
          ["method" #= ("post" :: B.ByteString), "access_token" #= token]
          Nothing
  r1 <- friendReq id1 id2 token1
  r2 <- friendReq id2 id1 token2
  unless r1 $ E.throwIO $ FbLibraryException "Couldn't make friend request."
  unless r2 $ E.throwIO $ FbLibraryException "Couldn't accept friend request."
  return ()

-- | Create an 'UserAccessToken' from a 'TestUser'.  It's incomplete
-- because it will not have the right expiration time.
incompleteTestUserAccessToken :: TestUser -> Maybe UserAccessToken
incompleteTestUserAccessToken t = do
  tokenData <- tuAccessToken t
  let farFuture = UTCTime (ModifiedJulianDay 100000) 0
  return (UserAccessToken (tuId t) tokenData farFuture)

-- | Same as 'getObject', but instead of parsing the result
-- as a JSON, it tries to parse either as "true" or "false".
-- Used only by the Test User API bindings.
getObjectBool
  :: (R.MonadResource m, R.MonadUnliftIO m, R.MonadThrow m)
  => Text
     -- ^ Path (should begin with a slash @\/@).
  -> [Argument]
     -- ^ Arguments to be passed to Facebook.
  -> Maybe (AccessToken anyKind)
     -- ^ Optional access token.
  -> FacebookT anyAuth m Bool
getObjectBool path query mtoken =
  runResourceInFb $
  do req <- fbreq path mtoken query
     response <- fbhttp req
     bs <- asBS response
     let respJson :: Maybe Value = decode (fromStrict bs)
     maybe
       (return False)
       (\val -> maybe (return False) return (parseMaybe isTrue val))
       respJson
  where
    isTrue :: Value -> Parser Bool
    isTrue val =
      withObject
        "success"
        (\obj -> do
           (status :: Bool) <- obj .: "success"
           return status)
        val

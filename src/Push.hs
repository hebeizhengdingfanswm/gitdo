{-# LANGUAGE OverloadedStrings #-}
module Push where

import Control.Applicative
import Network.Wreq
import Data.Aeson
import Data.Aeson.Lens
import Data.Maybe
import Control.Lens hiding ((.=))
import Control.Monad.Reader
import qualified Data.ByteString.Lazy as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Database.SQLite.Simple
import Turtle
import Shared

data PushOpts = PushOpts { _issueUser :: T.Text
                         , _issuePswd :: T.Text
                         , _user      :: T.Text
                         , _repo      :: T.Text
                         , _remove    :: Bool
                         } deriving (Show, Eq)

type ConfigM = ReaderT (Connection, PushOpts) IO

baseUrl :: String
baseUrl = "https://api.github.com/repos/"

cfgPath :: IsString a => a
cfgPath = ".git/hooks/gitdo.json"

-- TODO: Make issue message into a template that can be changed by the user
body :: PushOpts -> Todo -> T.Text
body cfg (Todo fp ln _ _ _) = "Autogenerated from [comment](https://github.com/"
                            <> _user cfg <> "/" <> _repo cfg <> "/blob/master/"
                            <> fromRight (toText fp) <> "#L" <> T.pack (show ln)
                            <> ")"


wreqOpts :: PushOpts -> Options
wreqOpts cfg =
  defaults & auth ?~ basicAuth (BSC.pack $ T.unpack $ _issueUser cfg)
                               (BSC.pack $ T.unpack $ _issuePswd cfg)

issuesUrl :: PushOpts -> String
issuesUrl cfg = baseUrl <> T.unpack (_user cfg) <> "/"
                        <> T.unpack (_repo cfg) <> "/issues"

-- TODO: Just pass the connection and opts as params to syncIssue
syncIssue :: Todo -> ConfigM ()
syncIssue t@(Todo fp ln td _ n) = do
  let ext = case n of Just v  -> "/" <> show v
                      Nothing -> ""
  (conn, cfg) <- ask
  let json = object ["title" .= td, "body" .= body cfg t]
  r <- liftIO $ postWith (wreqOpts cfg) (issuesUrl cfg <> ext) json
  let q = "UPDATE todos SET status=?, number=?" <>
          " WHERE file=? AND line=? AND todo=?;"
      err = "Could not sync with the server. Try again with gitdo push"
  json <- asValue r
  let val = json ^? responseBody
  case val ^. key "number" . asDouble of
    Just n  -> liftIO (execute conn q (Synced, n, fp, ln, td))
    Nothing -> liftIO $ die err
  liftIO $ TIO.putStrLn (todoMsg "SYNCED" t)

deleteIssue :: Todo -> ConfigM ()
deleteIssue t@(Todo fp ln td _ n) = do
  (conn, cfg) <- ask
  case n of
    Just num -> do
      let ext = "/" <> show num
          json = object ["state" .= ("closed" :: String)]
      r <- liftIO $ postWith (wreqOpts cfg) (issuesUrl cfg <> ext) json
      return ()
    Nothing -> return ()
  liftIO $ execute conn
             "DELETE FROM todos WHERE file=? AND line=? AND todo=? AND status=?"
             (fp, ln, td, Deleted)
  liftIO (TIO.putStrLn $ todoMsg "DELETE" t)

deleteIssues :: ConfigM ()
deleteIssues = do
  (conn, _) <- ask
  todos <- liftIO $ query conn "SELECT * FROM todos WHERE status=?" (Only Deleted)
  mapM_ deleteIssue todos

push :: PushOpts -> IO ()
push cfg = do
  conn <- open dbPath
  todos <- query conn "SELECT * FROM todos WHERE status IN (?, ?)"
                      (New, Updated)
  flip runReaderT (conn, cfg) $ mapM_ syncIssue todos
  if _remove cfg
  then runReaderT deleteIssues (conn, cfg)
  else return ()
    
  putStrLn "Done"

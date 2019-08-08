module DkTest
  ( 
    runDkTest
  ) where

import Bidirectional.Dunfield.Infer
import Bidirectional.Dunfield.Parser
import Bidirectional.Dunfield.Data (runStack)

import Data.Text.Prettyprint.Doc

showExpr :: Bool -> String -> IO ()
showExpr verbose x = do
  putStrLn $ "----------------------------------------------------------"
  putStrLn x
  let e = readExpr x 
  print e
  x <- runStack (infer [] e) verbose
  case x of
    Right (_, t) -> print $ "_ :: " <> pretty t
    Left err -> print $ "ERROR" <+> pretty err
  putStr "\n"

runDkTest :: IO ()
runDkTest = do
  -- primitives
  showExpr False "42"
  showExpr False "True"
  showExpr False "4.2"
  showExpr False "\"this is a string literal\""
  -- simple functions
  showExpr False "(\\x -> True)"
  showExpr False "(\\x -> True) 42"
  showExpr False "(\\x -> (\\y -> True) x) 42"

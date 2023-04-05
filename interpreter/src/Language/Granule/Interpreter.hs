{-                                       ___
                                        /\_ \
       __   _  _    __      ___   __  __\//\ \      __
     / _  \/\`'__\/ __ \  /' _ `\/\ \/\ \ \ \ \   /'__`\
    /\ \_\ \ \ \//\ \_\ \_/\ \/\ \ \ \_\ \ \_\ \_/\  __/
    \ \____ \ \_\\ \__/ \_\ \_\ \_\ \____/ /\____\ \____\
     \/___L\ \/_/ \/__/\/_/\/_/\/_/\/___/  \/____/\/____/
       /\____/
       \_/__/
-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

module Language.Granule.Interpreter where

import Control.Exception (SomeException, displayException, try)
import Control.Monad -- ((<=<), forM, forM_)
-- import Control.Monad.IO.Class (liftIO)
import Development.GitRev
import Data.Char (isSpace)
import Data.Either (isRight)
import Data.List (intercalate, isPrefixOf, stripPrefix)
import Data.List.Extra (breakOn)
import Data.List.NonEmpty (NonEmpty, toList)
import qualified Data.List.NonEmpty as NonEmpty (filter)
import Data.Maybe (fromMaybe)
import Data.Version (showVersion)
import System.Exit

import System.Directory (getAppUserDataDirectory, getCurrentDirectory)
import System.FilePath (takeFileName)
import qualified System.Timeout
import "Glob" System.FilePath.Glob (glob)
import Options.Applicative
import Options.Applicative.Help.Pretty (string)
import Control.Monad.State.Strict

import Language.Granule.Context
import Language.Granule.Checker.Checker
import Language.Granule.Checker.Monad (CheckerError(..))
import Language.Granule.Interpreter.Eval
import Language.Granule.Syntax.Def
import Language.Granule.Syntax.Expr
import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Type
import Language.Granule.Syntax.Preprocessor
import Language.Granule.Syntax.Parser
import Language.Granule.Syntax.Preprocessor.Ascii
import Language.Granule.Syntax.Pretty
import Language.Granule.Syntax.Span
import Language.Granule.Synthesis.DebugTree
import Language.Granule.Synthesis.RewriteHoles
import Language.Granule.Synthesis.Synth
import Language.Granule.Synthesis.Monad (Measurement)
import Language.Granule.Synthesis.LinearHaskell
import Language.Granule.Utils
import Paths_granule_interpreter (version)

main :: IO ()
main = do
    (globPatterns, config) <- getGrConfig
    if grShowVersion config
      then putStrLn $ "Granule version " <> showVersion version
      else
        if null globPatterns
          then runGrOnStdIn config
          else runGrOnFiles globPatterns config

-- | Run the checker and interpreter on a bunch of files
runGrOnFiles :: [FilePath] -> GrConfig -> IO ()
runGrOnFiles globPatterns config = let ?globals = grGlobals config in do
    pwd <- getCurrentDirectory
    results <- forM globPatterns $ \pattern -> do
      paths <- glob pattern
      case paths of
        [] -> do
          let result = Left $ NoMatchingFiles pattern
          printResult result
          return [result]
        _ -> forM paths $ \path -> do
          let fileName = if pwd `isPrefixOf` path then takeFileName path else path
          let ?globals = ?globals{ globalsSourceFilePath = Just fileName } in do
            printInfo $ "Checking " <> fileName <> "..."
            case globalsHaskellSynth ?globals of
              Just True -> do
                (ast, hsSrc) <- processHaskell path
                _ <- error $ show hsSrc
                result <- synthesiseLinearHaskell ast hsSrc
                case result of
                  Just srcModified -> do
                    writeHaskellToFile path srcModified
                    return $ Right NoEval
                  _ -> return $ Left $ FatalError "Couldn't synthesise Linear Haskell..."
              _ -> do
                src <- preprocess
                  (rewriter config)
                  (keepBackup config)
                  path
                  (literateEnvName config)
                result <- run config src
                printResult result
                return result
    if all isRight (concat results) then exitSuccess else exitFailure

runGrOnStdIn :: GrConfig -> IO ()
runGrOnStdIn config@GrConfig{..}
  = let ?globals = grGlobals{ globalsSourceFilePath = Just "stdin" } in do
      printInfo "Reading from stdin: confirm input with `enter+ctrl-d` or exit with `ctrl-c`"
      debugM "Globals" (show ?globals)
      result <- getContents >>= run config
      printResult result
      if isRight result then exitSuccess else exitFailure

-- print the result of running the checker and interpreter
printResult
  :: (?globals :: Globals)
  => Either InterpreterError InterpreterResult
  -> IO ()
printResult = \case
    Left err -> printError err
    Right (InterpreterResult val) -> putStrLn $ pretty val
    Right NoEval -> pure ()

{-| Run the input through the type checker and evaluate.
-}
run
  :: (?globals :: Globals)
  => GrConfig
  -> String
  -> IO (Either InterpreterError InterpreterResult)
run config input = let ?globals = fromMaybe mempty (grGlobals <$> getEmbeddedGrFlags input) <> ?globals in do
    result <- try $ parseAndDoImportsAndFreshenDefs input
    case result of
      Left (e :: SomeException) -> return . Left . ParseError $ show e
      Right (ast, extensions) ->
        -- update globals with extensions
        let ?globals = ?globals { globalsExtensions = extensions } in do
        -- Print to terminal when in debugging mode:
        debugM "Pretty-printed AST:" $ pretty ast
        debugM "Raw AST:" $ show ast
        -- Check and evaluate
        checked <- try $ check ast
        case checked of
          Left (e :: SomeException) -> return .  Left . FatalError $ displayException e
          Right (Left errs) -> do
            let holeErrors = getHoleMessages errs
            if ignoreHoles && length holeErrors == length errs && not (fromMaybe False $ globalsSynthesise ?globals)
              then do
                printSuccess $ "OK " ++ (blue $ "(but with " ++ show (length holeErrors) ++ " holes)")
                return $ Right NoEval
              else
                case (globalsRewriteHoles ?globals, holeErrors) of
                  (Just True, holes@(_:_)) ->
                    case (globalsSynthesise ?globals, length holeErrors == length errs) of
                      (Just True, True) -> do
                        holes' <- runSynthesiser holes ast (GradedBase `elem` globalsExtensions ?globals)
                        runHoleSplitter input config errs holes'
                      _ -> runHoleSplitter input config errs holes
                  _ ->  if fromMaybe False (globalsSynthesise ?globals) && not (null holeErrors) then do
                          _ <- runSynthesiser holeErrors ast (GradedBase `elem` globalsExtensions ?globals)
                          return $ Right NoEval
                          -- return . Left $ CheckerError errs
                        else return . Left $ CheckerError errs
          Right (Right (ast', derivedDefs)) -> do
            if noEval then do
              printSuccess "OK"
              return $ Right NoEval
            else do
              printSuccess "OK, evaluating..."
              result <- try $ eval (extendASTWith derivedDefs ast)
              case result of
                Left (e :: SomeException) ->
                  return . Left . EvalError $ displayException e
                Right Nothing -> if testing
                  then return $ Right NoEval
                  else return $ Left NoEntryPoint
                Right (Just result) -> do
                  return . Right $ InterpreterResult result

  where
    getHoleMessages :: NonEmpty CheckerError -> [CheckerError]
    getHoleMessages es =
      NonEmpty.filter (\ e -> case e of HoleMessage{} -> True; _ -> False) es

    runHoleSplitter :: (?globals :: Globals)
      => String
      -> GrConfig
      -> NonEmpty CheckerError
      -> [CheckerError]
      -> IO (Either InterpreterError InterpreterResult)
    runHoleSplitter input config errs holes = do
      noImportResult <- try $ parseAndFreshenDefs input
      case noImportResult of
        Left (e :: SomeException) -> return . Left . ParseError . show $ e
        Right (noImportAst, _) -> do
          let position = globalsHolePosition ?globals
          let relevantHoles = maybe holes (\ pos -> filter (holeInPosition pos) holes) position
          -- Associate the span with each generate cases
          let holeCases = concatMap (\h -> map (\(pats, e) -> (errLoc h, zip (getCtxtIds (holeVars h)) pats, e)) (cases h)) relevantHoles
          rewriteHoles input noImportAst (keepBackup config) holeCases
          case globalsSynthesise ?globals of
            Just True -> do
              -- printSuccess "Synthesised"
              return $ Right NoEval
            _         -> return . Left . CheckerError $ errs

    holeInPosition :: Pos -> CheckerError -> Bool
    holeInPosition pos (HoleMessage sp _ _ _ _ _ _) = spanContains pos sp
    holeInPosition _ _ = False


    runSynthesiser :: (?globals :: Globals) => [CheckerError] -> AST () () -> Bool -> IO [CheckerError]
    runSynthesiser holes ast isGradedBase = do
      let holesWithEmptyMeasurements = map (\h -> (h, Nothing, 0)) holes
      res <- synthesiseHoles ast holesWithEmptyMeasurements isGradedBase
      let (holes', measurements, _) = unzip3 res
      forM_ measurements (\m -> case m of (Just m') -> putStrLn $ show m' ; _ -> return ())
      return holes'


    synthesiseHoles :: (?globals :: Globals) => AST () () -> [(CheckerError, Maybe Measurement, Int)] -> Bool -> IO [(CheckerError, Maybe Measurement, Int)]
    synthesiseHoles _ [] _ = return []
    synthesiseHoles astSrc ((hole@(HoleMessage sp goal ctxt tyVars hVars synthCtxt@(Just (cs, defs, (Just defId, spec), index, hints, constructors)) hcases), aggregate, attemptNo):holes) isGradedBase = do
      -- TODO: this magic number shouldn't here I don't think...
      let timeout = if interactiveDebugging then maxBound :: Int else 10000000
      rest <- synthesiseHoles astSrc holes isGradedBase
      let (unrestricted, restricted) = case spec of
            Just (Spec _ _ _ comps) ->
              foldr (\(id, compTy) (unres, res) ->
                case lookup id defs of
                  Just tySch -> case compTy of
                        Just usage -> (unres, (id, (tySch, usage)):res)
                        _ -> ((id, tySch):unres, res)
                  _ -> (unres, res)
                ) ([], []) comps
            _ -> ([], [])
      res <- liftIO $ System.Timeout.timeout timeout $ 
                synthesiseGradedBase astSrc hole spec synEval hints index unrestricted restricted defId constructors ctxt (Forall nullSpan [] [] goal) cs 
      case res of
        Just ([], measurement) -> do
          return $ (HoleMessage sp goal ctxt tyVars hVars synthCtxt hcases, measurement, attemptNo) : rest
        Nothing -> do
          printInfo $ "No programs synthesised - Timeout after: " <> show (fromIntegral timeout / (10^(6 :: Integer)::Double))  <> "s"
          return $ (HoleMessage sp goal ctxt tyVars hVars synthCtxt hcases, Nothing, attemptNo) : rest
        Just (programs@(_:_), measurement) -> do
          printSynthOutput $ synthTreeToHtml (fst $ last $ programs) (snd $ last $ programs) 
          return $ (HoleMessage sp goal ctxt tyVars hVars synthCtxt [([], fst $ last $ programs)], measurement, attemptNo) : rest


    synthesiseHoles ast (hole:holes) isGradedBase = do
      rest <- synthesiseHoles ast holes isGradedBase
      return $ hole : rest

synEval :: (?globals :: Globals) => AST () () -> IO Bool 
synEval ast = do 
  res <- try $ eval ast 
  case res of 
    Left (e :: SomeException) -> do
      return False
    Right (Just (Constr _ idv [])) | mkId "True" == idv -> return True
    Right _ -> return False





-- | Get the flags embedded in the first line of a file, e.g.
-- "-- gr --no-eval"
getEmbeddedGrFlags :: String -> Maybe GrConfig
getEmbeddedGrFlags
  = foldr (<|>) Nothing
  . map getEmbeddedGrFlagsLine
  . take 3 -- only check for flags within the top 3 lines
  . filter (not . all isSpace)
  . lines
  where
    getEmbeddedGrFlagsLine
      = parseGrFlags . dropWhile isSpace
      <=< stripPrefix "gr" . dropWhile isSpace
      <=< stripPrefix "--" . dropWhile isSpace


parseGrFlags :: String -> Maybe GrConfig
parseGrFlags
  = pure . snd
  <=< getParseResult . execParserPure (prefs disambiguate) parseGrConfig . words


data GrConfig = GrConfig
  { grRewriter        :: Maybe (String -> String)
  , grKeepBackup      :: Maybe Bool
  , grLiterateEnvName :: Maybe String
  , grShowVersion     :: Bool
  , grGlobals         :: Globals
  }

rewriter :: GrConfig -> Maybe (String -> String)
rewriter c = grRewriter c <|> Nothing

keepBackup :: GrConfig -> Bool
keepBackup = fromMaybe False . grKeepBackup

literateEnvName :: GrConfig -> String
literateEnvName = fromMaybe "granule" . grLiterateEnvName

instance Semigroup GrConfig where
  c1 <> c2 = GrConfig
    { grRewriter    = grRewriter    c1 <|> grRewriter  c2
    , grKeepBackup      = grKeepBackup      c1 <|> grKeepBackup      c2
    , grLiterateEnvName = grLiterateEnvName c1 <|> grLiterateEnvName c2
    , grGlobals         = grGlobals         c1 <>  grGlobals         c2
    , grShowVersion     = grShowVersion     c1 ||  grShowVersion     c2
    }

instance Monoid GrConfig where
  mempty = GrConfig
    { grRewriter    = Nothing
    , grKeepBackup      = Nothing
    , grLiterateEnvName = Nothing
    , grGlobals         = mempty
    , grShowVersion     = False
    }

getGrConfig :: IO ([FilePath], GrConfig)
getGrConfig = do
    (globPatterns, configCLI) <- getGrCommandLineArgs
    configHome <- readUserConfig (grGlobals configCLI)
    pure (globPatterns, configCLI <> configHome)
  where
  -- TODO: UNIX specific
    readUserConfig :: Globals -> IO GrConfig
    readUserConfig globals = do
      let ?globals = globals
      try (getAppUserDataDirectory "granule") >>= \case
        Left (e :: SomeException) -> do
          debugM "Read user config" $ show e
          pure mempty
        Right configFile ->
          try (parseGrFlags <$> readFile configFile) >>= \case
            Left (e :: SomeException) -> do
              debugM "Read user config" $ show e
              pure mempty
            Right Nothing -> do
              printInfo . red . unlines $
                [ "Couldn't parse granule configuration file at " <> configFile
                , "Run `gr --help` to see a list of accepted flags."
                ]
              pure mempty
            Right (Just config) -> pure config


getGrCommandLineArgs :: IO ([FilePath], GrConfig)
getGrCommandLineArgs = customExecParser (prefs disambiguate) parseGrConfig

parseGrConfig :: ParserInfo ([FilePath], GrConfig)
parseGrConfig = info (go <**> helper) $ briefDesc
    <> (headerDoc . Just . string . unlines)
            [ "The Granule Interpreter"
            , "version: "     <> showVersion version
            , "branch: "      <> $(gitBranch)
            , "commit hash: " <> $(gitHash)
            , "commit date: " <> $(gitCommitDate)
            , if $(gitDirty) then "(uncommitted files present)" else ""
            ]
    <> footer "This software is provided under a BSD3 license and comes with NO WARRANTY WHATSOEVER.\
              \ Consult the LICENSE for further information."
  where
    go = do
        globPatterns <-
          many $ argument str $ metavar "GLOB_PATTERNS" <> action "file"
          <> (help . unwords)
            [ "Glob pattern for Granule source files. If the file extension is `.md`/`.tex`, the markdown/TeX preprocessor will be used."
            , "If none are given, input will be read from stdin."
            ]

        globalsDebugging <-
          flag Nothing (Just True)
            $ long "debug"
            <> help "Debug mode"

        globalsInteractiveDebugging <-
          flag Nothing (Just True)
            $ long "interactive"
            <> help "Interactive debug mode (for synthesis)"

        grShowVersion <-
          flag False True
            $ long "version"
            <> help "Show version"

        globalsSuppressInfos <-
          flag Nothing (Just True)
            $ long "no-info"
            <> help "Don't output info messages"

        globalsSuppressErrors <-
          flag Nothing (Just True)
            $ long "no-error"
            <> help "Don't output error messages"

        globalsNoColors <-
          flag Nothing (Just True)
            $ long "no-color"
            <> long "no-colour"
            <> help "Turn off colors in terminal output"

        globalsAlternativeColors <-
          flag Nothing (Just True)
            $ long "alternative-colors"
            <> long "alternative-colours"
            <> help "Print success messages in blue instead of green (may help with color blindness)"

        globalsNoEval <-
          flag Nothing (Just True)
            $ long "no-eval"
            <> help "Don't evaluate, only type-check"

        globalsTimestamp <-
          flag Nothing (Just True)
            $ long "timestamp"
            <> help "Print timestamp in info and error messages"

        globalsSolverTimeoutMillis <-
          (optional . option (auto @Integer))
            $ long "solver-timeout"
            <> (help . unwords)
            [ "SMT solver timeout in milliseconds (negative for unlimited)"
            , "Defaults to"
            , show solverTimeoutMillis <> "ms."
            ]

        globalsExampleLimit <-
          (optional . option (auto @Int))
            $ long "example-limit"
            <> (help . unwords)
            [ "Limit to the number of times synthed terms should be tried on examples before giving up"
            , "Defaults to"
            , show exampleLimit <> ""
            ]

        globalsIncludePath <-
          optional $ strOption
            $ long "include-path"
            <> help ("Path to the standard library. Defaults to "
                    <> show includePath)
            <> metavar "PATH"

        globalsEntryPoint <-
          optional $ strOption
            $ long "entry-point"
            <> help ("Program entry point. Defaults to " <> show entryPoint)
            <> metavar "ID"

        globalsRewriteHoles <-
          flag Nothing (Just True)
            $ long "rewrite-holes"
            <> help "WARNING: Destructively overwrite equations containing holes to pattern match on generated case-splits."

        globalsHoleLine <-
          optional . option (auto @Int)
            $ long "hole-line"
            <> help "The line where the hole you wish to rewrite is located."
            <> metavar "LINE"

        globalsHoleCol <-
          optional . option (auto @Int)
            $ long "hole-column"
            <> help "The column where the hole you wish to rewrite is located."
            <> metavar "COL"

        globalsSynthesise <-
          flag Nothing (Just True)
            $ long "synthesise"
            <> help "Turn on program synthesis. Must be used in conjunction with hole-line and hole-column"

        globalsIgnoreHoles <-
          flag Nothing (Just True)
            $ long "ignore-holes"
            <> help "Suppress information from holes (treat holes as well-typed)"

        globalsSubtractiveSynthesis <-
          flag Nothing (Just True)
           $ long "subtractive"
            <> help "Use subtractive mode for synthesis, rather than additive (default)."

        globalsAlternateSynthesisMode <-
          flag Nothing (Just True)
           $ long "alternate"
            <> help "Use alternate mode for synthesis (subtractive divisive, additive naive)"

        globalsGradeOnRule <-
          flag Nothing (Just True)
           $ long "gradeonrule"
            <> help "Use alternate grade-on-rule mode for synthesis"

        globalsHaskellSynth <-
          flag Nothing (Just True)
           $ long "linear-haskell"
            <> help "Synthesise Linear Haskell programs"

        grRewriter
          <- flag'
            (Just asciiToUnicode)
            (long "ascii-to-unicode" <> help "WARNING: Destructively overwrite ascii characters to multi-byte unicode.")
          <|> flag Nothing
            (Just unicodeToAscii)
            (long "unicode-to-ascii" <> help "WARNING: Destructively overwrite multi-byte unicode to ascii.")

        grKeepBackup <-
          flag Nothing (Just True)
            $ long "keep-backup"
            <> help "Keep a backup copy of the input file (only has an effect when destructively preprocessing.)"

        grLiterateEnvName <-
          optional $ strOption
            $ long "literate-env-name"
            <> help ("Name of the code environment to check in literate files. Defaults to "
                    <> show (literateEnvName mempty))

        globalsBenchmark <-
          flag Nothing (Just True)
           $ long "benchmark"
           <> help "Compute benchmarking results for the synthesis procedure."

        globalsBenchmarkRaw <-
          flag Nothing (Just True)
           $ long "raw-data"
           <> help "Show raw data of benchmarking data for synthesis."

        pure
          ( globPatterns
          , GrConfig
            { grRewriter
            , grKeepBackup
            , grLiterateEnvName
            , grShowVersion
            , grGlobals = Globals
              { globalsDebugging
              , globalsInteractiveDebugging
              , globalsNoColors
              , globalsAlternativeColors
              , globalsNoEval
              , globalsSuppressInfos
              , globalsSuppressErrors
              , globalsIgnoreHoles
              , globalsTimestamp
              , globalsTesting = Nothing
              , globalsSolverTimeoutMillis
              , globalsIncludePath
              , globalsSourceFilePath = Nothing
              , globalsEntryPoint
              , globalsRewriteHoles
              , globalsHolePosition = (,) <$> globalsHoleLine <*> globalsHoleCol
              , globalsSynthesise
              , globalsBenchmark
              , globalsBenchmarkRaw
              , globalsSubtractiveSynthesis
              , globalsAlternateSynthesisMode
              , globalsGradeOnRule
              , globalsHaskellSynth
              , globalsExampleLimit
              , globalsExtensions = []
              }
            }
          )
      where
        ?globals = mempty @Globals

data InterpreterError
  = ParseError String
  | CheckerError (NonEmpty CheckerError)
  | EvalError String
  | FatalError String
  | NoEntryPoint
  | NoMatchingFiles String
  deriving Show

data InterpreterResult
  = NoEval
  | InterpreterResult RValue
  deriving Show

instance UserMsg InterpreterError where
  title ParseError {} = "Parse error"
  title CheckerError {} = "Type checking failed"
  title EvalError {} = "Error during evaluation"
  title FatalError{} = "Fatal error"
  title NoEntryPoint{} = "No program entry point"
  title NoMatchingFiles{} = "User error"

  msg (ParseError m) = fst . breakOn "CallStack (from HasCallStack):" $ m -- TODO
  msg (CheckerError ms) = intercalate "\n\n" . map formatError . toList $ ms
  msg (EvalError m) = m
  msg (FatalError m) = m
  msg NoEntryPoint = "Program entry point `" <> entryPoint <> "` not found. A different one can be specified with `--entry-point`."
  msg (NoMatchingFiles p) = "The glob pattern `" <> p <> "` did not match any files."

{-| Agda main module.
-}
module Agda.Main where

import Control.Monad.Except

import Data.Maybe

import System.Environment
import System.Console.GetOpt

import Agda.Interaction.Base ( pattern RegularInteraction )
import Agda.Interaction.CommandLine
import Agda.Interaction.ExitCode (AgdaError(..), exitSuccess, exitAgdaWith)
import Agda.Interaction.Options
import Agda.Interaction.Options.Help (Help (..))
import Agda.Interaction.EmacsTop (mimicGHCi)
import Agda.Interaction.JSONTop (jsonREPL)
import Agda.Interaction.Imports (MaybeWarnings'(..))
import Agda.Interaction.FindFile ( SourceFile(SourceFile) )
import qualified Agda.Interaction.Imports as Imp
import qualified Agda.Interaction.Highlighting.Dot as Dot
import qualified Agda.Interaction.Highlighting.LaTeX as LaTeX
import Agda.Interaction.Highlighting.HTML

import Agda.TypeChecking.Monad
import qualified Agda.TypeChecking.Monad.Benchmark as Bench
import Agda.TypeChecking.Errors
import Agda.TypeChecking.Warnings
import Agda.TypeChecking.Pretty

import Agda.Compiler.Backend
import Agda.Compiler.Builtin

import Agda.VersionCommit

import Agda.Utils.FileName (absolute, AbsolutePath)
import Agda.Utils.Maybe (caseMaybe)
import Agda.Utils.Monad
import Agda.Utils.String
import qualified Agda.Utils.Benchmark as UtilsBench

import Agda.Utils.Impossible

-- | The main function
runAgda :: [Backend] -> IO ()
runAgda backends = runAgda' $ builtinBackends ++ backends

-- | The main function without importing built-in backends
runAgda' :: [Backend] -> IO ()
runAgda' backends = runTCMPrettyErrors $ do
  progName <- liftIO getProgName
  argv     <- liftIO getArgs
  opts     <- liftIO $ runOptM $ parseBackendOptions backends argv defaultOptions
  case opts of
    Left  err        -> liftIO $ optionError err
    Right (bs, opts) -> do
      setTCLens stBackends bs
      let enabled (Backend b) = isEnabled b (options b)
      interactor <- case filter enabled bs of
            []  -> return $ defaultInteraction opts
            bs' -> do
              -- NOTE: The existence of optInputFile is checked in @runAgdaWithOptions@
              -- before this block is executed.
              file <- liftIO $ caseMaybe (optInputFile opts) __IMPOSSIBLE__ absolute
              return $ backendInteraction file bs'
      () <$ runAgdaWithOptions backends generateHTML interactor progName opts

type Interactor a
    -- Setup/initialization action.
    -- This is separated so that errors can be reported in the appropriate format.
    = TCM ()
    -- Type-checking action
    -> (AbsolutePath -> TCM (Maybe Interface))
    -- Main transformed action.
    -> TCM a

defaultInteraction :: CommandLineOptions -> Interactor ()
defaultInteraction opts setup check
  | i         = do
      maybeFile <- liftIO $ case (optInputFile opts) of
                Nothing -> return Nothing
                Just rel -> Just <$> absolute rel
      runInteractionLoop maybeFile setup check
  -- Emacs and JSON interaction call typeCheck directly.
  | ghci      = mimicGHCi setup
  | json      = jsonREPL setup
  -- The default type-checking mode.
  | otherwise = do
      -- NOTE: The existence of optInputFile is checked in @runAgdaWithOptions@
      -- before this block is executed.
      file <- liftIO $ caseMaybe (optInputFile opts) __IMPOSSIBLE__ absolute
      setup
      void $ check file
  where
    i    = optInteractive     opts
    ghci = optGHCiInteraction opts
    json = optJSONInteraction opts

-- | Run Agda with parsed command line options and with a custom HTML generator
runAgdaWithOptions
  :: [Backend]          -- ^ Backends only for printing usage and version information
  -> TCM ()             -- ^ HTML generating action
  -> Interactor a       -- ^ Backend interaction
  -> String             -- ^ program name
  -> CommandLineOptions -- ^ parsed command line options
  -> TCM (Maybe a)
runAgdaWithOptions backends generateHTML interactor progName opts
      | Just hp <- optShowHelp opts = Nothing <$ liftIO (printUsage backends hp)
      | optShowVersion opts         = Nothing <$ liftIO (printVersion backends)
      | isNothing (optInputFile opts)
          && not (optInteractive opts)
          && not (optGHCiInteraction opts)
          && not (optJSONInteraction opts)
                            = Nothing <$ liftIO (printUsage backends GeneralHelp)
      | otherwise           = Just <$> do
          -- Main function.
          -- Bill everything to root of Benchmark trie.
          UtilsBench.setBenchmarking UtilsBench.BenchmarkOn
            -- Andreas, Nisse, 2016-10-11 AIM XXIV
            -- Turn benchmarking on provisionally, otherwise we lose track of time spent
            -- on e.g. LaTeX-code generation.
            -- Benchmarking might be turned off later by setCommandlineOptions

          Bench.billTo [] $
            interactor initialSetup checkFile
          `finally_` do
            -- Print benchmarks.
            Bench.print

            -- Print accumulated statistics.
            printStatistics 1 Nothing =<< useTC lensAccumStatistics
  where
    -- Options are fleshed out here so that (most) errors like
    -- "bad library path" are validated within the interactor,
    -- so that they are reported with the appropriate protocol/formatting.
    initialSetup :: TCM ()
    initialSetup = do
      opts <- addTrustedExecutables opts
      setCommandLineOptions opts

    checkFile :: AbsolutePath -> TCM (Maybe Interface)
    checkFile inputFile = do
        -- Andreas, 2013-10-30 The following 'resetState' kills the
        -- verbosity options.  That does not make sense (see fail/Issue641).
        -- 'resetState' here does not seem to serve any purpose,
        -- thus, I am removing it.
        -- resetState
          let mode = if optOnlyScopeChecking opts
                     then Imp.ScopeCheck
                     else Imp.TypeCheck RegularInteraction

          let file = SourceFile inputFile
          (i, mw) <- Imp.typeCheckMain file mode =<< Imp.sourceInfo file

          -- An interface is only generated if the mode is
          -- Imp.TypeCheck and there are no warnings.
          result <- case (mode, mw) of
            (Imp.ScopeCheck, _)  -> return Nothing
            (_, NoWarnings)      -> return $ Just i
            (_, SomeWarnings ws) -> do
              ws' <- applyFlagsToTCWarnings ws
              case ws' of
                []   -> return Nothing
                cuws -> tcWarningsToError cuws

          reportSDoc "main" 50 $ pretty i

          whenM (optGenerateHTML <$> commandLineOptions) $
            generateHTML

          whenM (isJust . optDependencyGraph <$> commandLineOptions) $
            Dot.generateDot $ i

          whenM (optGenerateLaTeX <$> commandLineOptions) $
            LaTeX.generateLaTeX i

          -- Print accumulated warnings
          ws <- tcWarnings . classifyWarnings <$> Imp.getAllWarnings AllWarnings
          unless (null ws) $ do
            let banner = text $ "\n" ++ delimiter "All done; warnings encountered"
            reportSDoc "warning" 1 $
              vcat $ punctuate "\n" $ banner : (prettyTCM <$> ws)

          return result



-- | Print usage information.
printUsage :: [Backend] -> Help -> IO ()
printUsage backends hp = do
  progName <- getProgName
  putStr $ usage standardOptions_ progName hp
  when (hp == GeneralHelp) $ mapM_ (putStr . backendUsage) backends

backendUsage :: Backend -> String
backendUsage (Backend b) =
  usageInfo ("\n" ++ backendName b ++ " backend options") $
    map void (commandLineFlags b)

-- | Print version information.
printVersion :: [Backend] -> IO ()
printVersion backends = do
  putStrLn $ "Agda version " ++ versionWithCommitInfo
  mapM_ putStrLn
    [ "  - " ++ name ++ " backend version " ++ ver
    | Backend Backend'{ backendName = name, backendVersion = Just ver } <- backends ]

-- | What to do for bad options.
optionError :: String -> IO ()
optionError err = do
  prog <- getProgName
  putStrLn $ "Error: " ++ err ++ "\nRun '" ++ prog ++ " --help' for help on command line options."
  exitAgdaWith OptionError

-- | Run a TCM action in IO; catch and pretty print errors.
runTCMPrettyErrors :: TCM () -> IO ()
runTCMPrettyErrors tcm = do
    r <- runTCMTop $ tcm `catchError` \err -> do
      s2s <- prettyTCWarnings' =<< Imp.getAllWarningsOfTCErr err
      s1  <- prettyError err
      let ss = filter (not . null) $ s2s ++ [s1]
      unless (null s1) (liftIO $ putStr $ unlines ss)
      throwError err
    case r of
      Right _ -> exitSuccess
      Left _  -> exitAgdaWith TCMError
  `catchImpossible` \e -> do
    putStr $ show e
    exitAgdaWith ImpossibleError

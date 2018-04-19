{-# LANGUAGE TemplateHaskell #-}

module LSP.Producer (
    produceAndUpdateState
) where

-- ###################################################################### --
-- Section: Imports
-- ###################################################################### --

-- Library
import Text.Megaparsec

-- Standard
import qualified Data.List.NonEmpty as NE(head)
import Language.Haskell.TH
import System.Environment
import System.Exit
import qualified Data.Map.Strict as Map
import Control.Monad
import Data.List

-- Encore
import Parser.Parser
import qualified AST.AST as AST
import AST.Desugarer
import AST.PrettyPrinter
import ModuleExpander
import Typechecker.Environment
import Typechecker.Prechecker(precheckProgram)
import Typechecker.Typechecker(typecheckProgram, checkForMainClass)
import Typechecker.TypeError
import Utils

-- LSP
import LSP.Data.TextDocument
import LSP.Data.Error
import LSP.Data.DataMap
import LSP.Data.Program
import LSP.Data.TextDocument

-- ###################################################################### --
-- Section: Support
-- ###################################################################### --

-- the following line of code resolves the standard path at compile time using Template Haskell
standardLibLocation = $(stringE . init =<< runIO (System.Environment.getEnv "ENCORE_MODULES" ))

preludePaths =
    [standardLibLocation ++ "/standard", standardLibLocation ++ "/prototype"]

-- ###################################################################### --
-- Section: Data
-- ###################################################################### --

--type ProgramMap = Map FilePath Program

-- ###################################################################### --
-- Section: Functions
-- ###################################################################### --

produceAndUpdateState :: FilePath -> DataMap -> IO (DataMap)
produceAndUpdateState path dataMap = do
    case Map.lookup path dataMap of
      Nothing -> return (dataMap)
      Just (program, textDocument) -> do
        let source = contents textDocument
        -- Parse program to produce AST
        (ast, error) <- case parseEncoreProgram path source of
          Right ast   -> return (ast, Nothing)
          Left error  -> return ((makeBlankAST path), Just error)

        case error of
          Just e -> do
            --print "Failed to parse program"
            let lspError = fromParsecError e
            let newProgram = Program {
                  program = ast,
                  errors = [lspError],
                  warnings = []
            }
            let newDataMap = Map.insert path (newProgram, textDocument) dataMap
            return (newDataMap)
          Nothing -> do
            -- Build program table from AST
            programTable <- buildProgramTable preludePaths preludePaths ast
            let desugaredTable = fmap desugarProgram programTable

            -- Convert the desugared table into a LSPState
            let newDataMap = convertFromProgramTable path desugaredTable

            -- Precheck and typecheck the table
            precheckedTable <- producerPrecheck newDataMap
            typecheckedTable <- producerTypecheck precheckedTable

            let cleanedMap = cleanDataMap typecheckedTable
            return (magicMerger dataMap cleanedMap)

cleanDataMap :: DataMap -> DataMap
cleanDataMap dataMap =
  Map.mapKeys cleanKey dataMap
  where
    cleanKey :: String -> String
    cleanKey key
      | isPrefixOf "./" key = drop 2 key
      | otherwise = key

magicMerger :: DataMap -> DataMap -> DataMap
magicMerger old new =
  Map.unionWith magicAux old new
  where
    magicAux :: LSPData -> LSPData -> LSPData
    magicAux _old _new = (fst _new, snd _old)

convertFromProgramTable :: FilePath -> ProgramTable -> DataMap
convertFromProgramTable path table =
    fmap (convertFromProgram path) table

convertToProgramTable :: DataMap -> ProgramTable
convertToProgramTable map =
    fmap convertToProgram map

convertFromProgram :: FilePath -> AST.Program -> LSPData
convertFromProgram path program =
  (makeProgram path, makeBlankTextDocument path)

convertToProgram :: LSPData -> AST.Program
convertToProgram (_program, textDocument) = program _program

-- ###################################################################### --
-- Section: Type checking
-- ###################################################################### --

producerPrecheckProgram :: (Map.Map FilePath LookupTable) -> LSPData -> IO (LSPData)
producerPrecheckProgram lookupTable lspData@(oldProgram, textDocument) = do
    case precheckProgram lookupTable (convertToProgram lspData) of
        (Right newProgram, newWarnings) ->
          return (Program {
              program = newProgram,
              errors = [],
              warnings = fromTCWarnings newWarnings
          }, textDocument)
        (Left error, newWarnings)->
          return (Program {
              program = program oldProgram,
              errors = [fromTCError error],
              warnings = fromTCWarnings newWarnings
          }, textDocument)

producerPrecheck :: DataMap -> IO (DataMap)
producerPrecheck programTable = do
    let lookupTable = fmap buildLookupTable (convertToProgramTable programTable)
    mapM (_producerPrecheck lookupTable) programTable
    where
        _producerPrecheck lookupTable program = do
            (precheckedProgram) <- (producerPrecheckProgram lookupTable program)
            return (precheckedProgram)

producerTypecheckProgram :: (Map.Map FilePath LookupTable) -> LSPData -> IO (LSPData)
producerTypecheckProgram lookupTable lspData@(oldProgram, textDocument) = do
    case typecheckProgram lookupTable (convertToProgram lspData) of
        (Right (_, newProgram), newWarnings) ->
          return (Program {
              program = newProgram,
              errors = [],
              warnings = fromTCWarnings newWarnings
          }, textDocument)
        (Left error, newWarnings)->
          return (Program {
              program = program oldProgram,
              errors = [fromTCError error],
              warnings = fromTCWarnings newWarnings
          }, textDocument)

producerTypecheck :: DataMap -> IO (DataMap)
producerTypecheck programTable = do
    let lookupTable = fmap buildLookupTable (convertToProgramTable programTable)
    mapM (_producerTypecheck lookupTable) programTable
    where
        _producerTypecheck lookupTable program = do
            (typecheckedProgram) <- (producerTypecheckProgram lookupTable program)
            return (typecheckedProgram)

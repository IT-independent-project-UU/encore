module LSP.Data.State (
    LSPState(..),
    initial,
    addTextDocument,
    closeTextDocument,
    changeTextDocument,
    produceTextDocument,
    compileDocument,
    getProgram
) where

-- ###################################################################### --
-- Section: Imports
-- ###################################################################### --

-- Standard
import Data.Map as Map hiding (foldr)

-- LSP
import LSP.Data.TextDocument
import LSP.Data.Program
import LSP.Data.DataMap
import LSP.Producer

-- ###################################################################### --
-- Section: Data
-- ###################################################################### --

data LSPState = LSPState {
    programs :: DataMap
} deriving (Show)

-- ###################################################################### --
-- Section: Functions
-- ###################################################################### --

initial :: LSPState
initial = LSPState {
    programs = Map.empty
}

addTextDocument :: TextDocument -> LSPState -> LSPState
addTextDocument newDocument (LSPState programs) =
    LSPState (Map.insert (uri newDocument) (makeBlankProgram (uri newDocument), newDocument) programs)

closeTextDocument :: TextDocumentIdentifier -> LSPState -> LSPState
closeTextDocument ident = LSPState . Map.delete (tdiUri ident) . programs

changeTextDocument :: TextDocumentChange -> LSPState -> LSPState
changeTextDocument documentChange state@(LSPState programs) =
    case Map.lookup (uri documentChange) programs of
        Nothing -> state
        Just (program, textDocument) ->
            LSPState $ Map.insert (uri documentChange)
                                  (program, (foldr applyTextDocumentChange textDocument (changes documentChange)))
                                  programs

produceTextDocument :: TextDocument -> LSPState -> IO (LSPState)
produceTextDocument textDocument state = do
  let path = uri textDocument
  dataMap <- produceAndUpdateState path (programs state)
  return (LSPState {programs = dataMap})

compileDocument :: String -> LSPState -> IO LSPState
compileDocument path = fmap LSPState . produceAndUpdateState path . programs

getProgram :: String -> LSPState -> Maybe Program
getProgram path = fmap fst . Map.lookup path . programs

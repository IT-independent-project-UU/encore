{-# LANGUAGE OverloadedStrings #-}

module LSP.Data.TextDocument (
    TextDocument(..),
    TextDocumentChange(..),
    TextDocumentIdentifier(..),
    uri,
    version,
    applyTextDocumentChange,
    makeBlankTextDocument
) where

-- ###################################################################### --
-- Section: Imports
-- ###################################################################### --

-- Standard
import Data.Aeson
import Data.String.Utils (split, join)

-- LSP
import LSP.Data.Position

-- ###################################################################### --
-- Section: Data
-- ###################################################################### --

data TextDocument = TextDocument {
    tdUri :: String,
    languageId :: String,
    tdVersion :: Int,
    contents :: String
} deriving (Show)

data TextDocumentChange = TextDocumentChange {
    tdcUri :: String,
    tdcVersion :: Int,
    changes :: [TextDocumentContentChange]
} deriving (Show)

data TextDocumentIdentifier = TextDocumentIdentifier {
    tdiUri :: String
} deriving (Show)

data TextDocumentContentChange = TextDocumentContentChange {
    range :: Range,
    rangeLength :: Int,
    text :: String
} deriving (Show)

-- ###################################################################### --
-- Section: Functions
-- ###################################################################### --

applyTextDocumentChange :: TextDocumentContentChange -> TextDocument -> TextDocument
applyTextDocumentChange textDocumentChange textDocument
    = TextDocument {
        tdUri      = uri textDocument,
        languageId = languageId textDocument,
        tdVersion  = version textDocument,
        contents   = applyTextChange (range textDocumentChange)
                                     (text textDocumentChange)
                                     (contents textDocument)
    }

applyTextChange :: Range -> String -> String -> String
applyTextChange _ replacement "" = replacement
applyTextChange ((startLine, startChar), (endLine, endChar))
                replacement
                text
    = let textLines = split "\n" text
          startSegment = join "\n" $ take startLine textLines ++
                                     [take startChar $ textLines !! startLine]
          endSegment = join "\n" $ (drop endChar $ textLines !! endLine) :
                                   drop (endLine+1) textLines
      in startSegment ++ replacement ++ endSegment

makeBlankTextDocument :: String -> TextDocument
makeBlankTextDocument name = TextDocument{
    tdUri      = name,
    languageId = "encore",
    tdVersion  = 1,
    contents   = ""
}

-- ###################################################################### --
-- Section: Type Classes
-- ###################################################################### --

class TextDocumentURI a where
    uri :: a -> String
class TextDocumentVersion a where
    version :: a -> Int

instance TextDocumentURI TextDocument where
    uri = tdUri
instance TextDocumentVersion TextDocument where
    version = tdVersion

instance TextDocumentURI TextDocumentChange where
    uri = tdcUri
instance TextDocumentVersion TextDocumentChange where
    version = tdcVersion

instance FromJSON TextDocument where
    parseJSON = withObject "params" $ \o -> do
        document <- o .: "textDocument"
        uri      <- document .: "uri"
        id       <- document .: "languageId"
        version  <- document .: "version"
        text     <- document .: "text"
        return TextDocument {
            tdUri = uri,
            languageId = id,
            tdVersion = version,
            contents = text
        }

instance FromJSON TextDocumentChange where
    parseJSON = withObject "params" $ \o -> do
        identifier  <- o .: "textDocument"
        uri         <- identifier .: "uri"
        version     <- identifier .: "version"

        changes     <- o .: "contentChanges"

        return TextDocumentChange {
            tdcUri = uri,
            tdcVersion = version,
            changes = changes
        }

instance FromJSON TextDocumentContentChange where
    parseJSON = withObject "TextDocumentChange" $ \o -> do
        range       <- o .: "range"
        rangeStart  <- range .: "start"
        startLine   <- rangeStart .: "line"
        startChar   <- rangeStart .: "character"
        rangeEnd    <- range .: "end"
        endLine     <- rangeEnd .: "line"
        endChar     <- rangeEnd .: "character"
        rangeLength <- o .: "rangeLength"
        text        <- o .: "text"

        return TextDocumentContentChange {
            range = ((startLine, startChar), (endLine, endChar)),
            rangeLength = rangeLength,
            text = text
        }

instance FromJSON TextDocumentIdentifier where
    parseJSON = withObject "textDocumentIdentifier" $ \o -> do
        uri <- o .: "uri"
        return TextDocumentIdentifier {
            tdiUri = uri
        }
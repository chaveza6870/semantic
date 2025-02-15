{-# LANGUAGE FlexibleContexts, LambdaCase, OverloadedStrings, TypeApplications #-}

module Data.Core.Pretty
  ( showCore
  , printCore
  , showFile
  , printFile
  , prettyCore
  ) where

import           Control.Effect.Reader
import           Data.Core
import           Data.File
import           Data.Functor.Const
import           Data.Name
import           Data.Scope
import           Data.Term
import           Data.Text.Prettyprint.Doc (Pretty (..), annotate, softline, (<+>))
import qualified Data.Text.Prettyprint.Doc as Pretty
import qualified Data.Text.Prettyprint.Doc.Render.String as Pretty
import qualified Data.Text.Prettyprint.Doc.Render.Terminal as Pretty

showCore :: Term Core User -> String
showCore = Pretty.renderString . Pretty.layoutSmart Pretty.defaultLayoutOptions . Pretty.unAnnotate . prettyCore Ascii

printCore :: Term Core User -> IO ()
printCore p = Pretty.putDoc (prettyCore Unicode p) *> putStrLn ""

showFile :: File (Term Core User) -> String
showFile = showCore . fileBody

printFile :: File (Term Core User) -> IO ()
printFile = printCore . fileBody

type AnsiDoc = Pretty.Doc Pretty.AnsiStyle

keyword, symbol, strlit, primitive :: AnsiDoc -> AnsiDoc
keyword = annotate (Pretty.colorDull Pretty.Cyan)
symbol  = annotate (Pretty.color Pretty.Yellow)
strlit  = annotate (Pretty.colorDull Pretty.Green)
primitive = keyword . mappend "#"

type Prec = Int

data Style = Unicode | Ascii

name :: User -> AnsiDoc
name n = encloseIf (needsQuotation n) (symbol "#{") (symbol "}") (pretty n)

with :: (Member (Reader Prec) sig, Carrier sig m) => Prec -> m a -> m a
with n = local (const n)

inParens :: (Member (Reader Prec) sig, Carrier sig m) => Prec -> m AnsiDoc -> m AnsiDoc
inParens amount go = do
  prec <- ask
  body <- with amount go
  pure (encloseIf (amount >= prec) (symbol "(") (symbol ")") body)

prettify :: (Member (Reader [AnsiDoc]) sig, Member (Reader Prec) sig, Carrier sig m)
         => Style
         -> Core (Const (m AnsiDoc)) a
         -> m AnsiDoc
prettify style = \case
  Let a -> pure $ keyword "let" <+> name a
  Const a :>> Const b -> do
    prec <- ask @Prec
    fore <- with 12 a
    aft  <- with 12 b

    let open  = symbol ("{" <> softline)
        close = symbol (softline <> "}")
        separator = ";" <> Pretty.line
        body = fore <> separator <> aft

    pure . Pretty.align $ encloseIf (12 > prec) open close (Pretty.align body)

  Lam n f -> inParens 11 $ do
    (x, body) <- bind n f
    pure (lambda <> x <+> arrow <+> body)

  Frame    -> pure $ primitive "frame"
  Unit     -> pure $ primitive "unit"
  Bool b   -> pure $ primitive (if b then "true" else "false")
  String s -> pure . strlit $ Pretty.viaShow s

  Const f :$ Const x -> inParens 11 $ (<+>) <$> f <*> x

  If (Const con) (Const tru) (Const fal) -> do
    con' <- "if"   `appending` con
    tru' <- "then" `appending` tru
    fal' <- "else" `appending` fal
    pure $ Pretty.sep [con', tru', fal']

  Load (Const p)   -> "load" `appending` p
  Edge Lexical (Const n) -> "lexical" `appending` n
  Edge Import (Const n) -> "import" `appending` n
  Const item :. Const body   -> inParens 4 $ do
    f <- item
    g <- body
    pure (f <> symbol "." <> g)

  Const lhs := Const rhs -> inParens 3 $ do
    f <- lhs
    g <- rhs
    pure (f <+> symbol "=" <+> g)

  -- Annotations are not pretty-printed, as it lowers the signal/noise ratio too profoundly.
  Ann _ (Const c) -> c
  where bind (Ignored x) f = let x' = name x in (,) x' <$> local (x':) (getConst (unScope f))
        lambda = case style of
          Unicode -> symbol "λ"
          Ascii   -> symbol "\\"
        arrow = case style of
          Unicode -> symbol "→"
          Ascii   -> symbol "->"


appending :: Functor f => AnsiDoc -> f AnsiDoc -> f AnsiDoc
appending k item = (keyword k <+>) <$> item

prettyCore :: Style -> Term Core User -> AnsiDoc
prettyCore s = run . runReader @Prec 0 . runReader @[AnsiDoc] [] . cata id (prettify s) bound (pure . name)
  where bound (Z _) = asks (head @AnsiDoc)
        bound (S n) = local (tail @AnsiDoc) n

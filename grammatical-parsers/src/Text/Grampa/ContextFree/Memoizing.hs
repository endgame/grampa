{-# LANGUAGE FlexibleContexts, GeneralizedNewtypeDeriving, InstanceSigs,
             RankNTypes, ScopedTypeVariables, TypeFamilies, UndecidableInstances #-}
module Text.Grampa.ContextFree.Memoizing (FailureInfo(..), ResultList(..), Parser(..), BinTree(..), (<<|>),
                                          fromResultList, reparseTails, longest, peg, terminalPEG)
where

import Control.Applicative
import Control.Monad (Monad(..), MonadPlus(..))
import Data.Function (on)
import Data.Foldable (toList)
import Data.Functor.Classes (Show1(..))
import Data.Functor.Compose (Compose(..))
import Data.List (genericLength, maximumBy, nub)
import Data.Semigroup (Semigroup(..))
import Data.Monoid (Monoid(mappend, mempty))
import Data.Monoid.Cancellative (LeftReductiveMonoid, isPrefixOf)
import Data.Monoid.Null (MonoidNull(null))
import Data.Monoid.Factorial (FactorialMonoid, length, splitPrimePrefix)
import Data.Monoid.Textual (TextualMonoid)
import qualified Data.Monoid.Factorial as Factorial
import qualified Data.Monoid.Textual as Textual
import Data.String (fromString)

import qualified Text.Parser.Char
import Text.Parser.Char (CharParsing)
import Text.Parser.Combinators (Parsing(..))
import Text.Parser.LookAhead (LookAheadParsing(..))
import Text.Parser.Token (TokenParsing)
import qualified Text.Parser.Token

import qualified Rank2

import Text.Grampa.Class (Lexical(..), GrammarParsing(..), MonoidParsing(..), MultiParsing(..), 
                          ParseResults, ParseFailure(..))
import Text.Grampa.Internal (BinTree(..), FailureInfo(..))
import qualified Text.Grampa.PEG.Backtrack.Measured as Backtrack

import Prelude hiding (iterate, length, null, showList, span, takeWhile)

-- | Parser for a context-free grammar with packrat-like sharing of parse results. It does not support left-recursive
-- grammars.
newtype Parser g s r = Parser{applyParser :: [(s, g (ResultList g s))] -> ResultList g s r}

data ResultList g s r = ResultList !(BinTree (ResultInfo g s r)) {-# UNPACK #-} !FailureInfo
data ResultInfo g s r = ResultInfo !Int ![(s, g (ResultList g s))] !r

instance Show r => Show (ResultList g s r) where
   show (ResultList l f) = "ResultList (" ++ shows l (") (" ++ shows f ")")

instance Show1 (ResultList g s) where
   liftShowsPrec _sp showList _prec (ResultList l f) rest = "ResultList " ++ showList (simplify <$> toList l) (shows f rest)
      where simplify (ResultInfo _ _ r) = r

instance Show r => Show (ResultInfo g s r) where
   show (ResultInfo l _ r) = "(ResultInfo @" ++ show l ++ " " ++ shows r ")"

instance Functor (ResultInfo g s) where
   fmap f (ResultInfo l t r) = ResultInfo l t (f r)

instance Functor (ResultList g s) where
   fmap f (ResultList l failure) = ResultList ((f <$>) <$> l) failure

instance Semigroup (ResultList g s r) where
   ResultList rl1 f1 <> ResultList rl2 f2 = ResultList (rl1 <> rl2) (f1 <> f2)

instance Monoid (ResultList g s r) where
   mempty = ResultList mempty mempty
   mappend = (<>)

instance Functor (Parser g i) where
   fmap f (Parser p) = Parser (fmap f . p)
   {-# INLINABLE fmap #-}

instance Applicative (Parser g i) where
   pure a = Parser (\rest-> ResultList (Leaf $ ResultInfo 0 rest a) mempty)
   Parser p <*> Parser q = Parser r where
      r rest = case p rest
               of ResultList results failure -> ResultList mempty failure <> foldMap continue results
      continue (ResultInfo l rest' f) = continue' l f (q rest')
      continue' l f (ResultList rs failure) = ResultList (adjust l f <$> rs) failure
      adjust l f (ResultInfo l' rest' a) = ResultInfo (l+l') rest' (f a)
   {-# INLINABLE pure #-}
   {-# INLINABLE (<*>) #-}

instance Alternative (Parser g i) where
   empty = Parser (\rest-> ResultList mempty $ FailureInfo (genericLength rest) ["empty"])
   Parser p <|> Parser q = Parser r where
      r rest = p rest <> q rest
   {-# INLINABLE (<|>) #-}

infixl 3 <<|>
(<<|>) :: Parser g s a -> Parser g s a -> Parser g s a
Parser p <<|> Parser q = Parser r where
   r rest = case p rest
            of rl@(ResultList EmptyTree _failure) -> rl <> q rest
               rl -> rl

instance Monad (Parser g i) where
   return = pure
   Parser p >>= f = Parser q where
      q rest = case p rest
               of ResultList results failure -> ResultList mempty failure <> foldMap continue results
      continue (ResultInfo l rest' a) = continue' l (applyParser (f a) rest')
      continue' l (ResultList rs failure) = ResultList (adjust l <$> rs) failure
      adjust l (ResultInfo l' rest' a) = ResultInfo (l+l') rest' a

instance MonadPlus (Parser g s) where
   mzero = empty
   mplus = (<|>)

instance Semigroup x => Semigroup (Parser g s x) where
   (<>) = liftA2 (<>)

instance Monoid x => Monoid (Parser g s x) where
   mempty = pure mempty
   mappend = liftA2 mappend

instance GrammarParsing Parser where
   type GrammarFunctor Parser = ResultList
   nonTerminal f = Parser p where
      p ((_, d) : _) = f d
      p _ = ResultList mempty (FailureInfo 0 ["NonTerminal at endOfInput"])
   {-# INLINE nonTerminal #-}

-- | Memoizing parser guarantees O(n²) performance for grammars with unambiguous productions, but provides no left
-- recursion support.
--
-- @
-- 'parseComplete' :: ("Rank2".'Rank2.Functor' g, 'FactorialMonoid' s) =>
--                  g (Memoizing.'Parser' g s) -> s -> g ('Compose' 'ParseResults' [])
-- @
instance MultiParsing Parser where
   type ResultFunctor Parser = Compose ParseResults []
   -- | Returns the list of all possible input prefix parses paired with the remaining input suffix.
   parsePrefix g input = Rank2.fmap (Compose . Compose . fromResultList input) (snd $ head $ parseTails g input)
   parseComplete :: forall g s. (Rank2.Functor g, FactorialMonoid s) =>
                    g (Parser g s) -> s -> g (Compose ParseResults [])
   parseComplete g input = Rank2.fmap ((snd <$>) . Compose . fromResultList input)
                              (snd $ head $ reparseTails close $ parseTails g input)
      where close = Rank2.fmap (<* endOfInput) g

parseTails :: (Rank2.Functor g, FactorialMonoid s) => g (Parser g s) -> s -> [(s, g (ResultList g s))]
parseTails g input = foldr parseTail [] (Factorial.tails input)
   where parseTail s parsedTail = parsed
            where parsed = (s,d):parsedTail
                  d      = Rank2.fmap (($ parsed) . applyParser) g

reparseTails :: Rank2.Functor g => g (Parser g s) -> [(s, g (ResultList g s))] -> [(s, g (ResultList g s))]
reparseTails _ [] = []
reparseTails final parsed@((s, _):_) = (s, gd):parsed
   where gd = Rank2.fmap (`applyParser` parsed) final

instance MonoidParsing (Parser g) where
   endOfInput = eof
   getInput = Parser p
      where p rest@((s, _):_) = ResultList (Leaf $ ResultInfo 0 rest s) mempty
            p [] = ResultList (Leaf $ ResultInfo 0 [] mempty) mempty
   anyToken = Parser p
      where p rest@((s, _):t) = case splitPrimePrefix s
                                of Just (first, _) -> ResultList (Leaf $ ResultInfo 1 t first) mempty
                                   _ -> ResultList mempty (FailureInfo (genericLength rest) ["anyToken"])
            p [] = ResultList mempty (FailureInfo 0 ["anyToken"])
   satisfy predicate = Parser p
      where p rest@((s, _):t) =
               case splitPrimePrefix s
               of Just (first, _) | predicate first -> ResultList (Leaf $ ResultInfo 1 t first) mempty
                  _ -> ResultList mempty (FailureInfo (genericLength rest) ["satisfy"])
            p [] = ResultList mempty (FailureInfo 0 ["satisfy"])
   satisfyChar predicate = Parser p
      where p rest@((s, _):t) =
               case Textual.characterPrefix s
               of Just first | predicate first -> ResultList (Leaf $ ResultInfo 1 t first) mempty
                  _ -> ResultList mempty (FailureInfo (genericLength rest) ["satisfyChar"])
            p [] = ResultList mempty (FailureInfo 0 ["satisfyChar"])
   satisfyCharInput predicate = Parser p
      where p rest@((s, _):t) =
               case Textual.characterPrefix s
               of Just first | predicate first -> ResultList (Leaf $ ResultInfo 1 t $ Factorial.primePrefix s) mempty
                  _ -> ResultList mempty (FailureInfo (genericLength rest) ["satisfyCharInput"])
            p [] = ResultList mempty (FailureInfo 0 ["satisfyCharInput"])
   scan s0 f = Parser (p s0)
      where p s rest@((i, _) : _) = ResultList (Leaf $ ResultInfo l (drop l rest) prefix) mempty
               where (prefix, _, _) = Factorial.spanMaybe' s f i
                     l = Factorial.length prefix
            p _ [] = ResultList (Leaf $ ResultInfo 0 [] mempty) mempty
   scanChars s0 f = Parser (p s0)
      where p s rest@((i, _) : _) = ResultList (Leaf $ ResultInfo l (drop l rest) prefix) mempty
               where (prefix, _, _) = Textual.spanMaybe_' s f i
                     l = Factorial.length prefix
            p _ [] = ResultList (Leaf $ ResultInfo 0 [] mempty) mempty
   takeWhile predicate = Parser p
      where p rest@((s, _) : _)
               | x <- Factorial.takeWhile predicate s, l <- Factorial.length x =
                    ResultList (Leaf $ ResultInfo l (drop l rest) x) mempty
            p [] = ResultList (Leaf $ ResultInfo 0 [] mempty) mempty
   takeWhile1 predicate = Parser p
      where p rest@((s, _) : _)
               | x <- Factorial.takeWhile predicate s, l <- Factorial.length x, l > 0 =
                    ResultList (Leaf $ ResultInfo l (drop l rest) x) mempty
            p rest = ResultList mempty (FailureInfo (genericLength rest) ["takeWhile1"])
   takeCharsWhile predicate = Parser p
      where p rest@((s, _) : _)
               | x <- Textual.takeWhile_ False predicate s, l <- Factorial.length x =
                    ResultList (Leaf $ ResultInfo l (drop l rest) x) mempty
            p [] = ResultList (Leaf $ ResultInfo 0 [] mempty) mempty
   takeCharsWhile1 predicate = Parser p
      where p rest@((s, _) : _)
               | x <- Textual.takeWhile_ False predicate s, l <- Factorial.length x, l > 0 =
                    ResultList (Leaf $ ResultInfo l (drop l rest) x) mempty
            p rest = ResultList mempty (FailureInfo (genericLength rest) ["takeCharsWhile1"])
   string s = Parser p where
      p rest@((s', _) : _)
         | s `isPrefixOf` s' = ResultList (Leaf $ ResultInfo l (Factorial.drop l rest) s) mempty
      p rest = ResultList mempty (FailureInfo (genericLength rest) ["string " ++ show s])
      l = Factorial.length s
   notSatisfy predicate = Parser p
      where p rest@((s, _):_)
               | Just (first, _) <- splitPrimePrefix s, 
                 predicate first = ResultList mempty (FailureInfo (genericLength rest) ["notSatisfy"])
            p rest = ResultList (Leaf $ ResultInfo 0 rest ()) mempty
   notSatisfyChar predicate = Parser p
      where p rest@((s, _):_)
               | Just first <- Textual.characterPrefix s, 
                 predicate first = ResultList mempty (FailureInfo (genericLength rest) ["notSatisfyChar"])
            p rest = ResultList (Leaf $ ResultInfo 0 rest ()) mempty
   {-# INLINABLE string #-}

instance MonoidNull s => Parsing (Parser g s) where
   try (Parser p) = Parser q
      where q rest = rewindFailure (p rest)
               where rewindFailure (ResultList rl (FailureInfo _pos _msgs)) =
                        ResultList rl (FailureInfo (genericLength rest) [])
   Parser p <?> msg  = Parser q
      where q rest = replaceFailure (p rest)
               where replaceFailure (ResultList EmptyTree (FailureInfo pos msgs)) =
                        ResultList EmptyTree (FailureInfo pos $ if pos == genericLength rest then [msg] else msgs)
                     replaceFailure rl = rl
   notFollowedBy (Parser p) = Parser (\input-> rewind input (p input))
      where rewind t (ResultList EmptyTree _) = ResultList (Leaf $ ResultInfo 0 t ()) mempty
            rewind t ResultList{} = ResultList mempty (FailureInfo (genericLength t) ["notFollowedBy"])
   skipMany p = go
      where go = pure () <|> p *> go
   unexpected msg = Parser (\t-> ResultList mempty $ FailureInfo (genericLength t) [msg])
   eof = Parser f
      where f rest@((s, _):_)
               | null s = ResultList (Leaf $ ResultInfo 0 rest ()) mempty
               | otherwise = ResultList mempty (FailureInfo (genericLength rest) ["endOfInput"])
            f [] = ResultList (Leaf $ ResultInfo 0 [] ()) mempty

instance MonoidNull s => LookAheadParsing (Parser g s) where
   lookAhead (Parser p) = Parser (\input-> rewind input (p input))
      where rewind t (ResultList rl failure) = ResultList (rewindInput t <$> rl) failure
            rewindInput t (ResultInfo _ _ r) = ResultInfo 0 t r

instance (Show s, TextualMonoid s) => CharParsing (Parser g s) where
   satisfy = satisfyChar
   string s = Textual.toString (error "unexpected non-character") <$> string (fromString s)
   char = satisfyChar . (==)
   notChar = satisfyChar . (/=)
   anyChar = satisfyChar (const True)
   text t = (fromString . Textual.toString (error "unexpected non-character")) <$> string (Textual.fromText t)

instance (Lexical g, LexicalConstraint Parser g s, Show s, TextualMonoid s) => TokenParsing (Parser g s) where
   someSpace = someLexicalSpace
   semi = lexicalSemicolon
   token = lexicalToken

fromResultList :: FactorialMonoid s => s -> ResultList g s r -> ParseResults [(s, r)]
fromResultList s (ResultList EmptyTree (FailureInfo pos msgs)) =
   Left (ParseFailure (length s - pos + 1) (nub msgs))
fromResultList _ (ResultList rl _failure) = Right (f <$> toList rl)
   where f (ResultInfo _ ((s, _):_) r) = (s, r)
         f (ResultInfo _ [] r) = (mempty, r)

-- | Turns a context-free parser into a backtracking PEG parser that consumes the longest possible prefix of the list
-- of input tails, opposite of 'peg'
longest :: Parser g s a -> Backtrack.Parser g [(s, g (ResultList g s))] a
longest p = Backtrack.Parser q where
   q rest = case applyParser p rest
            of ResultList EmptyTree failure -> Backtrack.NoParse failure
               ResultList rs _ -> parsed (maximumBy (compare `on` resultLength) rs)
   resultLength (ResultInfo l _ _) = l
   parsed (ResultInfo l s r) = Backtrack.Parsed l r s

-- | Turns a backtracking PEG parser of the list of input tails into a context-free parser, opposite of 'longest'
peg :: Backtrack.Parser g [(s, g (ResultList g s))] a -> Parser g s a
peg p = Parser q where
   q rest = case Backtrack.applyParser p rest
            of Backtrack.Parsed l result suffix -> ResultList (Leaf $ ResultInfo l suffix result) mempty
               Backtrack.NoParse failure -> ResultList mempty failure

-- | Turns a backtracking PEG parser into a context-free parser
terminalPEG :: Monoid s => Backtrack.Parser g s a -> Parser g s a
terminalPEG p = Parser q where
   q [] = case Backtrack.applyParser p mempty
            of Backtrack.Parsed l result _ -> ResultList (Leaf $ ResultInfo l [] result) mempty
               Backtrack.NoParse failure -> ResultList mempty failure
   q rest@((s, _):_) = case Backtrack.applyParser p s
                       of Backtrack.Parsed l result _ -> ResultList (Leaf $ ResultInfo l (drop l rest) result) mempty
                          Backtrack.NoParse failure -> ResultList mempty failure

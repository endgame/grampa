{-# LANGUAGE FlexibleContexts, GeneralizedNewtypeDeriving, InstanceSigs,
             RankNTypes, ScopedTypeVariables, TypeFamilies, UndecidableInstances #-}
module Text.Grampa.ContextFree.SortedMemoizing 
       (FailureInfo(..), ResultList(..), Parser(..), (<<|>),
        reparseTails, longest, peg, terminalPEG)
where

import Control.Applicative
import Control.Monad (Monad(..), MonadPlus(..))
import Data.Functor.Compose (Compose(..))
import Data.List (genericLength)
import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Semigroup (Semigroup(..))
import Data.Monoid (Monoid(mappend, mempty))
import Data.Monoid.Cancellative (LeftReductiveMonoid, isPrefixOf)
import Data.Monoid.Null (MonoidNull(null))
import Data.Monoid.Factorial (FactorialMonoid, splitPrimePrefix)
import Data.Monoid.Textual (TextualMonoid)
import qualified Data.Monoid.Factorial as Factorial
import qualified Data.Monoid.Textual as Textual
import Data.Semigroup (Semigroup((<>)))
import Data.String (fromString)

import qualified Text.Parser.Char
import Text.Parser.Char (CharParsing)
import Text.Parser.Combinators (Parsing(..))
import Text.Parser.LookAhead (LookAheadParsing(..))
import Text.Parser.Token (TokenParsing)
import qualified Text.Parser.Token

import qualified Rank2

import Text.Grampa.Class (Lexical(..), GrammarParsing(..), MonoidParsing(..), MultiParsing(..), AmbiguousParsing(..),
                          Ambiguous(Ambiguous), ParseResults)
import Text.Grampa.Internal (FailureInfo(..), ResultList(..), ResultsOfLength(..), fromResultList)
import qualified Text.Grampa.PEG.Backtrack.Measured as Backtrack

import Prelude hiding (iterate, length, null, showList, span, takeWhile)

-- | Parser for a context-free grammar with packrat-like sharing of parse results. It does not support left-recursive
-- grammars.
newtype Parser g s r = Parser{applyParser :: [(s, g (ResultList g s))] -> ResultList g s r}

instance Functor (Parser g i) where
   fmap f (Parser p) = Parser (fmap f . p)
   {-# INLINE fmap #-}

instance Applicative (Parser g i) where
   pure a = Parser (\rest-> ResultList [ResultsOfLength 0 rest (a:|[])] mempty)
   Parser p <*> Parser q = Parser r where
      r rest = case p rest
               of ResultList results failure -> ResultList mempty failure <> foldMap continue results
      continue (ResultsOfLength l rest' fs) = foldMap (continue' l $ q rest') fs
      continue' l (ResultList rs failure) f = ResultList (adjust l f <$> rs) failure
      adjust l f (ResultsOfLength l' rest' as) = ResultsOfLength (l+l') rest' (f <$> as)
   {-# INLINABLE pure #-}
   {-# INLINABLE (<*>) #-}

instance Alternative (Parser g i) where
   empty = Parser (\rest-> ResultList mempty $ FailureInfo (genericLength rest) [])
   Parser p <|> Parser q = Parser r where
      r rest = p rest <> q rest
   {-# INLINE (<|>) #-}
   {-# INLINABLE empty #-}

infixl 3 <<|>
(<<|>) :: Parser g s a -> Parser g s a -> Parser g s a
Parser p <<|> Parser q = Parser r where
   r rest = case p rest
            of rl@(ResultList [] _failure) -> rl <> q rest
               rl -> rl

instance Monad (Parser g i) where
   return = pure
   (>>) = (*>)
   Parser p >>= f = Parser q where
      q rest = case p rest
               of ResultList results failure -> ResultList mempty failure <> foldMap continue results
      continue (ResultsOfLength l rest' rs) = foldMap (continue' l . flip applyParser rest' . f) rs
      continue' l (ResultList rs failure) = ResultList (adjust l <$> rs) failure
      adjust l (ResultsOfLength l' rest' rs) = ResultsOfLength (l+l') rest' rs

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
      where p rest@((s, _):_) = ResultList [ResultsOfLength 0 rest (s:|[])] mempty
            p [] = ResultList [ResultsOfLength 0 [] (mempty:|[])] mempty
   anyToken = Parser p
      where p rest@((s, _):t) = case splitPrimePrefix s
                                of Just (first, _) -> ResultList [ResultsOfLength 1 t (first:|[])] mempty
                                   _ -> ResultList mempty (FailureInfo (genericLength rest) ["anyToken"])
            p [] = ResultList mempty (FailureInfo 0 ["anyToken"])
   satisfy predicate = Parser p
      where p rest@((s, _):t) =
               case splitPrimePrefix s
               of Just (first, _) | predicate first -> ResultList [ResultsOfLength 1 t (first:|[])] mempty
                  _ -> ResultList mempty (FailureInfo (genericLength rest) ["satisfy"])
            p [] = ResultList mempty (FailureInfo 0 ["satisfy"])
   satisfyChar predicate = Parser p
      where p rest@((s, _):t) =
               case Textual.characterPrefix s
               of Just first | predicate first -> ResultList [ResultsOfLength 1 t (first:|[])] mempty
                  _ -> ResultList mempty (FailureInfo (genericLength rest) ["satisfyChar"])
            p [] = ResultList mempty (FailureInfo 0 ["satisfyChar"])
   satisfyCharInput predicate = Parser p
      where p rest@((s, _):t) =
               case Textual.characterPrefix s
               of Just first | predicate first -> ResultList [ResultsOfLength 1 t (Factorial.primePrefix s:|[])] mempty
                  _ -> ResultList mempty (FailureInfo (genericLength rest) ["satisfyCharInput"])
            p [] = ResultList mempty (FailureInfo 0 ["satisfyCharInput"])
   scan s0 f = Parser (p s0)
      where p s rest@((i, _) : _) = ResultList [ResultsOfLength l (drop l rest) (prefix:|[])] mempty
               where (prefix, _, _) = Factorial.spanMaybe' s f i
                     l = Factorial.length prefix
            p _ [] = ResultList [ResultsOfLength 0 [] (mempty:|[])] mempty
   scanChars s0 f = Parser (p s0)
      where p s rest@((i, _) : _) = ResultList [ResultsOfLength l (drop l rest) (prefix:|[])] mempty
               where (prefix, _, _) = Textual.spanMaybe_' s f i
                     l = Factorial.length prefix
            p _ [] = ResultList [ResultsOfLength 0 [] (mempty:|[])] mempty
   takeWhile predicate = Parser p
      where p rest@((s, _) : _)
               | x <- Factorial.takeWhile predicate s, l <- Factorial.length x =
                    ResultList [ResultsOfLength l (drop l rest) (x:|[])] mempty
            p [] = ResultList [ResultsOfLength 0 [] (mempty:|[])] mempty
   takeWhile1 predicate = Parser p
      where p rest@((s, _) : _)
               | x <- Factorial.takeWhile predicate s, l <- Factorial.length x, l > 0 =
                    ResultList [ResultsOfLength l (drop l rest) (x:|[])] mempty
            p rest = ResultList mempty (FailureInfo (genericLength rest) ["takeWhile1"])
   takeCharsWhile predicate = Parser p
      where p rest@((s, _) : _)
               | x <- Textual.takeWhile_ False predicate s, l <- Factorial.length x =
                    ResultList [ResultsOfLength l (drop l rest) (x:|[])] mempty
            p [] = ResultList [ResultsOfLength 0 [] (mempty:|[])] mempty
   takeCharsWhile1 predicate = Parser p
      where p rest@((s, _) : _)
               | x <- Textual.takeWhile_ False predicate s, l <- Factorial.length x, l > 0 =
                    ResultList [ResultsOfLength l (drop l rest) (x:|[])] mempty
            p rest = ResultList mempty (FailureInfo (genericLength rest) ["takeCharsWhile1"])
   string s = Parser p where
      p rest@((s', _) : _)
         | s `isPrefixOf` s' = ResultList [ResultsOfLength l (Factorial.drop l rest) (s:|[])] mempty
      p rest = ResultList mempty (FailureInfo (genericLength rest) ["string " ++ show s])
      l = Factorial.length s
   notSatisfy predicate = Parser p
      where p rest@((s, _):_)
               | Just (first, _) <- splitPrimePrefix s, 
                 predicate first = ResultList mempty (FailureInfo (genericLength rest) ["notSatisfy"])
            p rest = ResultList [ResultsOfLength 0 rest (():|[])] mempty
   notSatisfyChar predicate = Parser p
      where p rest@((s, _):_)
               | Just first <- Textual.characterPrefix s, 
                 predicate first = ResultList mempty (FailureInfo (genericLength rest) ["notSatisfyChar"])
            p rest = ResultList [ResultsOfLength 0 rest (():|[])] mempty
   {-# INLINABLE string #-}

instance MonoidNull s => Parsing (Parser g s) where
   try (Parser p) = Parser q
      where q rest = rewindFailure (p rest)
               where rewindFailure (ResultList rl (FailureInfo _pos _msgs)) =
                        ResultList rl (FailureInfo (genericLength rest) [])
   Parser p <?> msg  = Parser q
      where q rest = replaceFailure (p rest)
               where replaceFailure (ResultList [] (FailureInfo pos msgs)) =
                        ResultList [] (FailureInfo pos $ if pos == genericLength rest then [msg] else msgs)
                     replaceFailure rl = rl
   notFollowedBy (Parser p) = Parser (\input-> rewind input (p input))
      where rewind t (ResultList [] _) = ResultList [ResultsOfLength 0 t (():|[])] mempty
            rewind t ResultList{} = ResultList mempty (FailureInfo (genericLength t) ["notFollowedBy"])
   skipMany p = go
      where go = pure () <|> p *> go
   unexpected msg = Parser (\t-> ResultList mempty $ FailureInfo (genericLength t) [msg])
   eof = Parser f
      where f rest@((s, _):_)
               | null s = ResultList [ResultsOfLength 0 rest (():|[])] mempty
               | otherwise = ResultList mempty (FailureInfo (genericLength rest) ["endOfInput"])
            f [] = ResultList [ResultsOfLength 0 [] (():|[])] mempty

instance MonoidNull s => LookAheadParsing (Parser g s) where
   lookAhead (Parser p) = Parser (\input-> rewind input (p input))
      where rewind _ rl@(ResultList [] _) = rl
            rewind t (ResultList rl failure) = ResultList [ResultsOfLength 0 t $ foldr1 (<>) (results <$> rl)] failure
            results (ResultsOfLength _ _ r) = r

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

instance AmbiguousParsing (Parser g s) where
   ambiguous (Parser p) = Parser q
      where q rest | ResultList rs failure <- p rest = ResultList (groupByLength <$> rs) failure
            groupByLength (ResultsOfLength l rest rs) = ResultsOfLength l rest (Ambiguous rs :| [])

-- | Turns a context-free parser into a backtracking PEG parser that consumes the longest possible prefix of the list
-- of input tails, opposite of 'peg'
longest :: Parser g s a -> Backtrack.Parser g [(s, g (ResultList g s))] a
longest p = Backtrack.Parser q where
   q rest = case applyParser p rest
            of ResultList [] failure -> Backtrack.NoParse failure
               ResultList rs _ -> parsed (last rs)
   parsed (ResultsOfLength l s (r:|_)) = Backtrack.Parsed l r s

-- | Turns a backtracking PEG parser of the list of input tails into a context-free parser, opposite of 'longest'
peg :: Backtrack.Parser g [(s, g (ResultList g s))] a -> Parser g s a
peg p = Parser q where
   q rest = case Backtrack.applyParser p rest
            of Backtrack.Parsed l result suffix -> ResultList [ResultsOfLength l suffix (result:|[])] mempty
               Backtrack.NoParse failure -> ResultList mempty failure

-- | Turns a backtracking PEG parser into a context-free parser
terminalPEG :: Monoid s => Backtrack.Parser g s a -> Parser g s a
terminalPEG p = Parser q where
   q [] = case Backtrack.applyParser p mempty
            of Backtrack.Parsed l result _ -> ResultList [ResultsOfLength l [] (result:|[])] mempty
               Backtrack.NoParse failure -> ResultList mempty failure
   q rest@((s, _):_) = case Backtrack.applyParser p s
                       of Backtrack.Parsed l result _ -> 
                             ResultList [ResultsOfLength l (drop l rest) (result:|[])] mempty
                          Backtrack.NoParse failure -> ResultList mempty failure

-- | This module exports the templates for automatic instance deriving of "Transformation.Deep" type classes. The most
-- common way to use it would be
--
-- > import qualified Transformation.Deep.TH
-- > data MyDataType f' f = ...
-- > $(Transformation.Deep.TH.deriveFunctor ''MyDataType)
--

{-# Language TemplateHaskell #-}
-- Adapted from https://wiki.haskell.org/A_practical_Template_Haskell_Tutorial

module Transformation.Deep.TH (deriveAll, deriveFunctor, deriveFoldable, deriveTraversable)
where

import Control.Applicative (liftA2)
import Control.Monad (replicateM)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Language.Haskell.TH
import Language.Haskell.TH.Syntax (BangType, VarBangType, getQ, putQ)

import qualified Transformation
import qualified Transformation.Deep
import qualified Transformation.Full
import qualified Rank2.TH


data Deriving = Deriving { _constructor :: Name, _variableN :: Name, _variable1 :: Name }

deriveAll :: Name -> Q [Dec]
deriveAll ty = foldr f (pure []) [Rank2.TH.deriveFunctor, Rank2.TH.deriveFoldable, Rank2.TH.deriveTraversable,
                                  Transformation.Deep.TH.deriveFunctor, Transformation.Deep.TH.deriveFoldable,
                                  Transformation.Deep.TH.deriveTraversable]
   where f derive rest = (<>) <$> derive ty <*> rest

deriveFunctor :: Name -> Q [Dec]
deriveFunctor ty = do
   t <- varT <$> newName "t"
   p <- varT <$> newName "p"
   q <- varT <$> newName "q"
   (instanceType, cs) <- reifyConstructors ty
   let deepConstraint ty = conT ''Transformation.Deep.Functor `appT` t `appT` ty `appT` p `appT` q
       fullConstraint ty = conT ''Transformation.Full.Functor `appT` t `appT` ty `appT` p `appT` q
   (constraints, dec) <- genDeepmap deepConstraint fullConstraint instanceType cs
   sequence [instanceD (cxt $ map pure constraints)
                       (deepConstraint instanceType)
                       [pure dec]]

deriveFoldable :: Name -> Q [Dec]
deriveFoldable ty = do
   t <- varT <$> newName "t"
   f <- varT <$> newName "f"
   m <- varT <$> newName "m"
   (instanceType, cs) <- reifyConstructors ty
   let deepConstraint ty = conT ''Transformation.Deep.Foldable `appT` t `appT` ty `appT` f `appT` m
       fullConstraint ty = conT ''Transformation.Full.Foldable `appT` t `appT` ty `appT` f `appT` m
   (constraints, dec) <- genFoldMap deepConstraint fullConstraint instanceType cs
   sequence [instanceD (cxt (appT (conT ''Monoid) m : map pure constraints))
                       (deepConstraint instanceType)
                       [pure dec]]

deriveTraversable :: Name -> Q [Dec]
deriveTraversable ty = do
   t <- varT <$> newName "t"
   p <- varT <$> newName "p"
   q <- varT <$> newName "q"
   m <- varT <$> newName "m"
   (instanceType, cs) <- reifyConstructors ty
   let deepConstraint ty = conT ''Transformation.Deep.Traversable `appT` t `appT` ty `appT` p `appT` q `appT` m
       fullConstraint ty = conT ''Transformation.Full.Traversable `appT` t `appT` ty `appT` p `appT` q `appT` m
   (constraints, dec) <- genTraverse deepConstraint fullConstraint instanceType cs
   sequence [instanceD (cxt (appT (conT ''Monad) m : map pure constraints))
                       (deepConstraint instanceType)
                       [pure dec]]

substitute :: Type -> Q Type -> Q Type -> Q Type
substitute resultType = liftA2 substitute'
   where substitute' instanceType argumentType =
            substituteVars (substitutions resultType instanceType) argumentType
         substitutions (AppT t1 (VarT name1)) (AppT t2 (VarT name2)) = (name1, name2) : substitutions t1 t2
         substitutions _t1 _t2 = []
         substituteVars subs (VarT name) = VarT (fromMaybe name $ lookup name subs)
         substituteVars subs (AppT t1 t2) = AppT (substituteVars subs t1) (substituteVars subs t2)
         substituteVars _ t = t

reifyConstructors :: Name -> Q (TypeQ, [Con])
reifyConstructors ty = do
   (TyConI tyCon) <- reify ty
   (tyConName, tyVars, _kind, cs) <- case tyCon of
      DataD _ nm tyVars kind cs _   -> return (nm, tyVars, kind, cs)
      NewtypeD _ nm tyVars kind c _ -> return (nm, tyVars, kind, [c])
      _ -> fail "deriveApply: tyCon may not be a type synonym."

   let (KindedTV tyVar  (AppT (AppT ArrowT StarT) StarT) :
        KindedTV tyVar' (AppT (AppT ArrowT StarT) StarT) : _) = reverse tyVars
       instanceType           = foldl apply (conT tyConName) (reverse $ drop 2 $ reverse tyVars)
       apply t (PlainTV name)    = appT t (varT name)
       apply t (KindedTV name _) = appT t (varT name)

   putQ (Deriving tyConName tyVar' tyVar)
   return (instanceType, cs)

genDeepmap :: (Q Type -> Q Type) -> (Q Type -> Q Type) -> Q Type -> [Con] -> Q ([Type], Dec)
genDeepmap deepConstraint fullConstraint instanceType cs = do
   (constraints, clauses) <- unzip <$> mapM (genDeepmapClause deepConstraint fullConstraint instanceType) cs
   return (concat constraints, FunD '(Transformation.Deep.<$>) clauses)

genFoldMap :: (Q Type -> Q Type) -> (Q Type -> Q Type) -> Q Type -> [Con] -> Q ([Type], Dec)
genFoldMap deepConstraint fullConstraint instanceType cs = do
   (constraints, clauses) <- unzip <$> mapM (genFoldMapClause deepConstraint fullConstraint instanceType) cs
   return (concat constraints, FunD 'Transformation.Deep.foldMap clauses)

genTraverse :: (Q Type -> Q Type) -> (Q Type -> Q Type) -> Q Type -> [Con] -> Q ([Type], Dec)
genTraverse deepConstraint fullConstraint instanceType cs = do
   (constraints, clauses) <- unzip
     <$> mapM (genTraverseClause genTraverseField deepConstraint fullConstraint instanceType) cs
   return (concat constraints, FunD 'Transformation.Deep.traverse clauses)

genDeepmapClause :: (Q Type -> Q Type) -> (Q Type -> Q Type) -> Q Type -> Con -> Q ([Type], Clause)
genDeepmapClause deepConstraint fullConstraint instanceType (NormalC name fieldTypes) = do
   t          <- newName "t"
   fieldNames <- replicateM (length fieldTypes) (newName "x")
   let pats = [varP t, parensP (conP name $ map varP fieldNames)]
       constraintsAndFields = zipWith newField fieldNames fieldTypes
       newFields = map (snd <$>) constraintsAndFields
       body = normalB $ appsE $ conE name : newFields
       newField :: Name -> BangType -> Q ([Type], Exp)
       newField x (_, fieldType) = genDeepmapField (varE t) fieldType deepConstraint fullConstraint (varE x) id
   constraints <- (concat . (fst <$>)) <$> sequence constraintsAndFields
   (,) constraints <$> clause pats body []
genDeepmapClause deepConstraint fullConstraint instanceType (RecC name fields) = do
   f <- newName "f"
   x <- newName "x"
   let body = normalB $ recConE name $ (snd <$>) <$> constraintsAndFields
       constraintsAndFields = map newNamedField fields
       newNamedField :: VarBangType -> Q ([Type], (Name, Exp))
       newNamedField (fieldName, _, fieldType) =
          ((,) fieldName <$>)
          <$> genDeepmapField (varE f) fieldType deepConstraint fullConstraint (appE (varE fieldName) (varE x)) id
   constraints <- (concat . (fst <$>)) <$> sequence constraintsAndFields
   (,) constraints <$> clause [varP f, varP x] body []
genDeepmapClause deepConstraint fullConstraint instanceType
                 (GadtC [name] fieldTypes (AppT (AppT resultType (VarT tyVar')) (VarT tyVar))) =
   do Just (Deriving tyConName _tyVar' _tyVar) <- getQ
      putQ (Deriving tyConName tyVar' tyVar)
      genDeepmapClause (deepConstraint . substitute resultType instanceType)
                       (fullConstraint . substitute resultType instanceType)
                       instanceType (NormalC name fieldTypes)
genDeepmapClause deepConstraint fullConstraint instanceType
                 (RecGadtC [name] fields (AppT (AppT resultType (VarT tyVar')) (VarT tyVar))) =
   do Just (Deriving tyConName _tyVar' _tyVar) <- getQ
      putQ (Deriving tyConName tyVar' tyVar)
      genDeepmapClause (deepConstraint . substitute resultType instanceType)
                       (fullConstraint . substitute resultType instanceType)
                       instanceType (RecC name fields)
genDeepmapClause deepConstraint fullConstraint instanceType (ForallC _vars _cxt con) =
   genDeepmapClause deepConstraint fullConstraint instanceType con

genFoldMapClause :: (Q Type -> Q Type) -> (Q Type -> Q Type) -> Q Type -> Con -> Q ([Type], Clause)
genFoldMapClause deepConstraint fullConstraint instanceType (NormalC name fieldTypes) = do
   t          <- newName "t"
   fieldNames <- replicateM (length fieldTypes) (newName "x")
   let pats = [varP t, parensP (conP name $ map varP fieldNames)]
       constraintsAndFields = zipWith newField fieldNames fieldTypes
       newFields = map (snd <$>) constraintsAndFields
       body | null newFields = [| mempty |]
            | otherwise = foldr1 append newFields
       append a b = [| $(a) <> $(b) |]
       newField :: Name -> BangType -> Q ([Type], Exp)
       newField x (_, fieldType) = genFoldMapField (varE t) fieldType deepConstraint fullConstraint (varE x) id
   constraints <- (concat . (fst <$>)) <$> sequence constraintsAndFields
   (,) constraints <$> clause pats (normalB body) []
genFoldMapClause deepConstraint fullConstraint instanceType (RecC _name fields) = do
   t <- newName "t"
   x <- newName "x"
   let body | null fields = [| mempty |]
            | otherwise = foldr1 append $ (snd <$>) <$> constraintsAndFields
       append a b = [| $(a) <> $(b) |]
       constraintsAndFields = map newNamedField fields
       newNamedField :: VarBangType -> Q ([Type], Exp)
       newNamedField (fieldName, _, fieldType) =
          genFoldMapField (varE t) fieldType deepConstraint fullConstraint (appE (varE fieldName) (varE x)) id
   constraints <- (concat . (fst <$>)) <$> sequence constraintsAndFields
   (,) constraints <$> clause [varP t, varP x] (normalB body) []
genFoldMapClause deepConstraint fullConstraint instanceType
                 (GadtC [name] fieldTypes (AppT (AppT resultType (VarT tyVar')) (VarT tyVar))) =
   do Just (Deriving tyConName _tyVar' _tyVar) <- getQ
      putQ (Deriving tyConName tyVar' tyVar)
      genFoldMapClause (deepConstraint . substitute resultType instanceType)
                       (fullConstraint . substitute resultType instanceType)
                       instanceType (NormalC name fieldTypes)
genFoldMapClause deepConstraint fullConstraint instanceType
                 (RecGadtC [name] fields (AppT (AppT resultType (VarT tyVar')) (VarT tyVar))) =
   do Just (Deriving tyConName _tyVar' _tyVar) <- getQ
      putQ (Deriving tyConName tyVar' tyVar)
      genFoldMapClause (deepConstraint . substitute resultType instanceType)
                       (fullConstraint . substitute resultType instanceType)
                       instanceType (RecC name fields)
genFoldMapClause deepConstraint fullConstraint instanceType (ForallC _vars _cxt con) =
   genFoldMapClause deepConstraint fullConstraint instanceType con

type GenTraverseFieldType = Q Exp -> Type -> (Q Type -> Q Type) -> (Q Type -> Q Type) -> Q Exp -> (Q Exp -> Q Exp)
                            -> Q ([Type], Exp)

genTraverseClause :: GenTraverseFieldType -> (Q Type -> Q Type) -> (Q Type -> Q Type) -> Q Type -> Con
                  -> Q ([Type], Clause)
genTraverseClause genTraverseField deepConstraint fullConstraint instanceType (NormalC name fieldTypes) = do
   t          <- newName "t"
   fieldNames <- replicateM (length fieldTypes) (newName "x")
   let pats = [varP t, parensP (conP name $ map varP fieldNames)]
       constraintsAndFields = zipWith newField fieldNames fieldTypes
       newFields = map (snd <$>) constraintsAndFields
       body | null fieldTypes = [| pure $(conE name) |]
            | otherwise = fst $ foldl apply (conE name, False) newFields
       apply (a, False) b = ([| $(a) <$> $(b) |], True)
       apply (a, True) b = ([| $(a) <*> $(b) |], True)
       newField :: Name -> BangType -> Q ([Type], Exp)
       newField x (_, fieldType) = genTraverseField (varE t) fieldType deepConstraint fullConstraint (varE x) id
   constraints <- (concat . (fst <$>)) <$> sequence constraintsAndFields
   (,) constraints <$> clause pats (normalB body) []
genTraverseClause genTraverseField deepConstraint fullConstraint instanceType (RecC name fields) = do
   f <- newName "f"
   x <- newName "x"
   let constraintsAndFields = map newNamedField fields
       body | null fields = [| pure $(conE name) |]
            | otherwise = fst (foldl apply (conE name, False) $ map (snd . snd <$>) constraintsAndFields)
       apply (a, False) b = ([| $(a) <$> $(b) |], True)
       apply (a, True) b = ([| $(a) <*> $(b) |], True)
       newNamedField :: VarBangType -> Q ([Type], (Name, Exp))
       newNamedField (fieldName, _, fieldType) =
          ((,) fieldName <$>)
          <$> genTraverseField (varE f) fieldType deepConstraint fullConstraint (appE (varE fieldName) (varE x)) id
   constraints <- (concat . (fst <$>)) <$> sequence constraintsAndFields
   (,) constraints <$> clause [varP f, varP x] (normalB body) []
genTraverseClause genTraverseField deepConstraint fullConstraint instanceType
                  (GadtC [name] fieldTypes (AppT (AppT resultType (VarT tyVar')) (VarT tyVar))) =
   do Just (Deriving tyConName _tyVar' _tyVar) <- getQ
      putQ (Deriving tyConName tyVar' tyVar)
      genTraverseClause genTraverseField
        (deepConstraint . substitute resultType instanceType)
        (fullConstraint . substitute resultType instanceType)
        instanceType (NormalC name fieldTypes)
genTraverseClause genTraverseField deepConstraint fullConstraint instanceType
                  (RecGadtC [name] fields (AppT (AppT resultType (VarT tyVar')) (VarT tyVar))) =
   do Just (Deriving tyConName _tyVar' _tyVar) <- getQ
      putQ (Deriving tyConName tyVar' tyVar)
      genTraverseClause genTraverseField
                        (deepConstraint . substitute resultType instanceType)
                        (fullConstraint . substitute resultType instanceType)
                        instanceType (RecC name fields)
genTraverseClause genTraverseField deepConstraint fullConstraint instanceType (ForallC _vars _cxt con) =
   genTraverseClause genTraverseField deepConstraint fullConstraint instanceType con

genDeepmapField :: Q Exp -> Type -> (Q Type -> Q Type) -> (Q Type -> Q Type) -> Q Exp -> (Q Exp -> Q Exp)
                -> Q ([Type], Exp)
genDeepmapField trans fieldType deepConstraint fullConstraint fieldAccess wrap = do
   Just (Deriving _ typeVarN typeVar1) <- getQ
   case fieldType of
     AppT ty (AppT (AppT con v1) v2) | ty == VarT typeVar1, v1 == VarT typeVarN, v2 == VarT typeVarN ->
        (,) <$> ((:[]) <$> fullConstraint (pure con))
            <*> appE (wrap [| ($trans Transformation.Full.<$>) |]) fieldAccess
     AppT ty _  | ty == VarT typeVar1 ->
                  (,) [] <$> (wrap (varE 'Transformation.fmap `appE` trans) `appE` fieldAccess)
     AppT (AppT con v1) v2 | v1 == VarT typeVarN, v2 == VarT typeVar1 ->
        (,) <$> ((:[]) <$> deepConstraint (pure con))
            <*> appE (wrap [| Transformation.Deep.fmap $trans |]) fieldAccess
     AppT t1 t2 | t1 /= VarT typeVar1 ->
        genDeepmapField trans t2 deepConstraint fullConstraint fieldAccess (wrap . appE (varE '(<$>)))
     SigT ty _kind -> genDeepmapField trans ty deepConstraint fullConstraint fieldAccess wrap
     ParensT ty -> genDeepmapField trans ty deepConstraint fullConstraint fieldAccess wrap
     _ -> (,) [] <$> fieldAccess

genFoldMapField :: Q Exp -> Type -> (Q Type -> Q Type) -> (Q Type -> Q Type) -> Q Exp -> (Q Exp -> Q Exp)
                -> Q ([Type], Exp)
genFoldMapField trans fieldType deepConstraint fullConstraint fieldAccess wrap = do
   Just (Deriving _ typeVarN typeVar1) <- getQ
   case fieldType of
     AppT ty (AppT (AppT con v1) v2) | ty == VarT typeVar1, v1 == VarT typeVarN, v2 == VarT typeVarN ->
        (,) <$> ((:[]) <$> fullConstraint (pure con))
            <*> appE (wrap [| Transformation.Full.foldMap $trans |]) fieldAccess
     AppT ty _  | ty == VarT typeVar1 ->
                  (,) [] <$> (wrap (varE 'Transformation.foldMap `appE` trans) `appE` fieldAccess)
     AppT (AppT con v1) v2 | v1 == VarT typeVarN, v2 == VarT typeVar1 ->
        (,) <$> ((:[]) <$> deepConstraint (pure con))
            <*> appE (wrap [| Transformation.Deep.foldMap $trans |]) fieldAccess
     AppT t1 t2 | t1 /= VarT typeVar1 ->
        genFoldMapField trans t2 deepConstraint fullConstraint fieldAccess (wrap . appE (varE 'foldMap))
     SigT ty _kind -> genFoldMapField trans ty deepConstraint fullConstraint fieldAccess wrap
     ParensT ty -> genFoldMapField trans ty deepConstraint fullConstraint fieldAccess wrap
     _ -> (,) [] <$> [| mempty |]

genTraverseField :: GenTraverseFieldType
genTraverseField trans fieldType deepConstraint fullConstraint fieldAccess wrap = do
   Just (Deriving _ typeVarN typeVar1) <- getQ
   case fieldType of
     AppT ty (AppT (AppT con v1) v2) | ty == VarT typeVar1, v1 == VarT typeVarN, v2 == VarT typeVarN ->
        (,) <$> ((:[]) <$> fullConstraint (pure con))
            <*> appE (wrap [| Transformation.Full.traverse $trans |]) fieldAccess
     AppT ty _  | ty == VarT typeVar1 ->
                  (,) [] <$> (wrap (varE 'Transformation.traverse `appE` trans) `appE` fieldAccess)
     AppT (AppT con v1) v2 | v1 == VarT typeVarN, v2 == VarT typeVar1 ->
        (,) <$> ((:[]) <$> deepConstraint (pure con))
            <*> appE (wrap [| Transformation.Deep.traverse $trans |]) fieldAccess
     AppT t1 t2 | t1 /= VarT typeVar1 ->
        genTraverseField trans t2 deepConstraint fullConstraint fieldAccess (wrap . appE (varE 'traverse))
     SigT ty _kind -> genTraverseField trans ty deepConstraint fullConstraint fieldAccess wrap
     ParensT ty -> genTraverseField trans ty deepConstraint fullConstraint fieldAccess wrap
     _ -> (,) [] <$> [| pure $fieldAccess |]

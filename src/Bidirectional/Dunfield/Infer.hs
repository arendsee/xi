module Bidirectional.Dunfield.Infer ( infer ) where

import Bidirectional.Dunfield.Data
import Bidirectional.Dunfield.Parser
import Control.Applicative ((<|>))
import Control.Monad.Trans (liftIO)

run :: Show a => String -> [(String, String)] -> Stack a -> Stack a
run s args x = do
  incDepth
  d <- depth
  liftIO . putStrLn $ (take d $ repeat '>') <> " " <> s
  mapM writeArg args
  output <- x
  liftIO . putStrLn $ (take d $ repeat '<') <> " " <> s
  decDepth
  liftIO . putStrLn $ "  return: " <> show output
  return output

writeArg :: (String, String) -> Stack ()
writeArg (name, arg) = do
  liftIO . putStrLn $ "  " <> name <> ": " <> arg

runSubtype :: String -> Type -> Type -> Gamma -> Stack Gamma -> Stack Gamma
runSubtype s t1 t2 g x
  = run ("subtype " <> s) [("t1", show t1), ("t2", show t2), ("g", show g)] x

runInstantiate :: String -> Type -> Type -> Gamma -> Stack Gamma -> Stack Gamma
runInstantiate s t1 t2 g x
  = run ("instantiate " <> s) [("ta", show t1), ("tb", show t2), ("g", show g)] x

runInfer :: String -> Gamma -> Expr -> Stack (Gamma, Type) -> Stack (Gamma, Type)
runInfer s g e x
  = run ("infer " <> s) [("g", show g), ("e", show e)] x

runCheck :: String -> Gamma -> Type -> Expr -> Stack (Gamma, Type) -> Stack (Gamma, Type)
runCheck s g t e x
  = run ("check " <> s) [("g", show g), ("t", show t), ("e", show e)] x

runDerive :: String -> Gamma -> Expr -> Type -> Stack (Gamma, Type) -> Stack (Gamma, Type)
runDerive s g e t x
  = run ("derive " <> s) [("g", show g), ("e", show e), ("t", show t)] x


-- | substitute all appearances of a given variable with an existential
-- [t/v]A
substitute :: TVar -> Type -> Type
substitute v t@(VarT v')
  | v == v' = ExistT v
  | otherwise = t
substitute v (FunT t1 t2) = FunT (substitute v t1) (substitute v t2)
substitute v t@(Forall x t')
  | v /= x = Forall x (substitute v t')
  | otherwise = t -- allows shadowing of the variable
substitute _ t = t


-- | Apply a context to a type (See Dunfield Figure 8).
apply :: Gamma -> Type -> Type
-- [G]l = l
apply _ UniT = UniT
-- [G]a = a
apply _ a@(VarT v) = a
-- [G](A->B) = ([G]A -> [G]B)
apply g (FunT a b) = FunT (apply g a) (apply g b)
-- [G]Forall a.a = forall a. [G]a
apply g (Forall x a) = Forall x (apply g a)
-- [G[a=t]]a = [G[a=t]]t
apply g a@(ExistT v) = case lookupT v g of
  (Just t') -> apply g t' -- reduce an existential; strictly smaller term
  Nothing -> a


-- | Ensure a given type variable is not free within a given type
occursCheck :: Type -> TVar -> Stack TVar
occursCheck UniT v = return v
occursCheck (VarT v') v 
  | v' == v = throwError OccursCheckFail
  | otherwise = return v
occursCheck (FunT t1 t2) v = do
  occursCheck t1 v
  occursCheck t2 v
occursCheck (Forall v' t) v
  | v' == v = return v -- variable is bound, we are done
  | otherwise = occursCheck t v -- else recurse
occursCheck (ExistT v') v
  | v' == v = throwError OccursCheckFail -- existentials count
  | otherwise = return v'


-- | type 1 is more polymorphic than type 2 (Dunfield Figure 9)
subtype :: Type -> Type -> Gamma -> Stack Gamma
--
-- ----------------------------------------- Unit
--  G |- 1 <: 1 -| G
subtype UniT UniT g = runSubtype "Unit" UniT UniT g $ do
  return g
--
-- ----------------------------------------- <:Var
--  G[a] |- a <: a -| G[a]
subtype t1@(VarT a1) t2@(VarT a2) g = runSubtype "<:Var" t1 t2 g $ do
  if (a1 == a2)
  then return g
  else throwError SubtypeError
--
-- ----------------------------------------- <:Exvar
--  G[E.a] |- Ea <: Ea -| G[E.a]
subtype a@(ExistT a1) b@(ExistT a2) g = runSubtype "<:Exvar" a b g $ do
  if (a1 == a2)
  then return g
  else instantiate a b g
--  g1 |- A1 <: B1 -| g2
--  g2 |- [g2]A2 <: [g2]B2 -| g3
-- ----------------------------------------- <:-->
--  g1 |- A1 -> A2 <: B1 -> B2 -| g3
subtype x@(FunT a1 a2) y@(FunT b1 b2) g1 = runSubtype "<:-->" x y g1 $ do
  g2 <- subtype a1 b1 g1
  subtype (apply g2 a2) (apply g2 b2) g2
--  g1,>Ea,Ea |- [Ea/x]A <: B -| g2,>Ea,g3
-- ----------------------------------------- <:ForallL
--  g1 |- Forall x . A <: B -| g2
subtype t@(Forall x a) b g = runSubtype "<:ForallL" t b g $ do
  subtype (substitute x a) b (g +> MarkG x +> ExistG x) >>= cut (MarkG x)
--  g1,a |- A :> B -| g2,a,g3
-- ----------------------------------------- <:ForallR
--  g1 |- A <: Forall a. B -| g2
subtype a t@(Forall v b) g = runSubtype "<:ForallR" a t g $ do
  subtype a b (g +> VarG v) >>= cut (VarG v)
--  Ea not in FV(a)
--  g1[Ea] |- Ea <=: A -| g2
-- ----------------------------------------- <:InstantiateL
--  g1[Ea] |- Ea <: A -| g2
subtype a@(ExistT v) b g = runSubtype "<:InstantiateL" a b g $ do
  occursCheck b v
  instantiate a b g 
--  Ea not in FV(a)
--  g1[Ea] |- A <=: Ea -| g2
-- ----------------------------------------- <:InstantiateR
--  g1[Ea] |- A <: Ea -| g2
subtype a b@(ExistT v) g = runSubtype "<:InstantiateR" a b g $ do
  occursCheck a v
  instantiate a b g 


-- | Dunfield Figure 10 -- type-level structural recursion
instantiate :: Type -> Type -> Gamma -> Stack Gamma

-- ==== Left rules: Ea <: B ===================================================
--  g1 |- t
-- ----------------------------------------- instLSolve
--  g1,Ea,g2 |- Ea <=: t -| g1,Ea=t,g2
instantiate ta@(ExistT v) tb@(VarT _) g1 = runInstantiate "instLSolve" ta tb g1 $ do
  accessWith (const (SolvedG v tb)) ta g1
--  g1[Ea2, Ea1, Ea=Ea1->Ea2] |- A1 <=: Ea1 -| g2
--  g2 |- Ea2 <=: [g2]A2 -| g3
-- ----------------------------------------- InstLArr
--  g1[Ea] |- Ea <=: A1 -> A2 -| g3
instantiate ta@(ExistT v) tb@(FunT t1 t2) g1 = runInstantiate "instLArr" ta tb g1 $ do
  ea1 <- newvar
  ea2 <- newvar
  g2 <- instantiate t1 ea1 (g1 +> ea2 +> ea1 +> SolvedG v (FunT ea1 ea2))
  g3 <- instantiate ea2 (apply g2 t2) g2
  return g3
--
-- ----------------------------------------- InstLAllR
--
instantiate ta@(ExistT _) tb@(Forall v2 t2) g1 = runInstantiate "InstLAllR" ta tb g1 $ do
  instantiate ta t2 (g1 +> VarG v2) >>= cut (VarG v2)

-- ==== Symmetric rule: Ea <: Eb ==============================================
-- InstLReach or instRReach -- each rule eliminates an existential
-- Replace the rightmost with leftmost (G[a][b] --> L,a,M,b=a,R)
instantiate ta@(ExistT v1) tb@(ExistT v2) g1 = runInstantiate "Inst[LR]Reach" ta tb g1 $ do
  case access2 ta tb g1 of
    -- InstLReach
    (Just (ls, x, ms, _, rs)) -> return $ ls <> (x:ms) <> (SolvedG v2 ta:rs)
    Nothing -> case access2 tb ta g1 of
      -- InstRReach
      (Just (ls, x, ms, _, rs)) -> return $ ls <> (x:ms) <> (SolvedG v1 tb:rs)
      Nothing -> throwError UnknownError

-- ==== Right rules: A <: Eb ==================================================
--  g1 |- t
-- ----------------------------------------- InstRSolve
--  g1,Ea,g2 |- t <=: Ea -| g1,Ea=t,g2
instantiate ta@(VarT t) tb@(ExistT v) g1 = runInstantiate "InstRSolve" ta tb g1 $ do
  accessWith (const (SolvedG v ta)) tb g1
--  g1[Ea2,Ea1,Ea=Ea1->Ea2] |- Ea1 <=: A1 -| g2
--  g2 |- [g2]A2 <=: Ea2 -| g3
-- ----------------------------------------- InstRArr
--  g1[Ea] |- A1 -> A2 <=: Ea -| g3
instantiate ta@(FunT t1 t2) tb@(ExistT v) g1 = runInstantiate "InstRSolve" ta tb g1 $ do
  ea1 <- newvar
  ea2 <- newvar
  g2 <- instantiate ea1 t1 $ g1 +> ea2 +> ea1 +> SolvedG v (FunT ea1 ea2)
  g3 <- instantiate (apply g2 t2) ea2 g2
  return g3
--  g1[Ea],>Eb,Eb |- [Eb/x]B <=: Ea -| g2,>Eb,g3
-- ----------------------------------------- InstRAllL
--  g1[Ea] |- Forall x. B <=: Ea -| g2
instantiate ta@(Forall x b) tb@(ExistT _) g1 = runInstantiate "InstRSolve" ta tb g1 $ do
  instantiate
      (substitute x b)             -- [Eb/x]B
      tb                           -- Ea
      (g1 +> MarkG x +> ExistG x)  -- g1[Ea],>Eb,Eb
  >>= cut (MarkG x)
-- bad
instantiate t1 t2 g = runInstantiate "error" t1 t2 g $ do
  return g

infer :: Gamma -> Expr -> Stack (Gamma, Type)
--
-- ----------------------------------------- 1l=>
--  g |- () => 1 -| g
infer g e@UniE = runInfer "1l" g e $ do
  return (g, UniT) 
--  (x:A) in g
-- ----------------------------------------- Var
--  g |- x => A -| g
infer g e@(VarE v) = runInfer "Var" g e $ do
  case lookupE e g of
    (Just t) -> return (g, t)
    Nothing  -> throwError UnboundVariable
--  g1,Ea,Eb,x:Ea |- e <= Eb -| g2,x:Ea,g3
-- ----------------------------------------- -->I=>
--  g1 |- \x.e => Ea -> Eb
infer g1 e@(LamE v e2) = runInfer "LamE" g1 e $ do
  a <- newvar
  b <- newvar
  let ann = AnnG (VarE v) a
      g' = g1 +> a +> b +> ann
  (g'', t) <- check g' b e2
  g2 <- cut ann g''
  return (g2, t)
--  g1 |- e1 => A -| g2
--  g2 |- [g2]A o e2 =>> C -| g3
-- ----------------------------------------- -->E
--  g1 |- e1 e2 => C -| g3
infer g1 e@(AppE e1 e2) = runInfer "AppE" g1 e $ do
  (g2, a) <- infer g1 e1
  derive g2 e2 (apply g2 a)
--  g1 |- A
--  g1 |- e <= A -| g2
-- ----------------------------------------- Anno
--  g1 |- (e:A) => A -| g2
infer g e1@(AnnE e t) = runInfer "Anno" g e1 $ do
  check g t e


-- | Pattern matches against each type
check :: Gamma -> Type -> Expr -> Stack (Gamma, Type)
--
-- ----------------------------------------- 1l
--  g |- () <= 1 -| g
check g UniT UniE = runCheck "1l" g UniT UniE $ do
  return (g, UniT)
check g UniT e = runCheck "1l-error" g UniT e $ do
  throwError TypeMismatch
--  g1,x:A |- e <= B -| g2,x:A,g3
-- ----------------------------------------- -->I
--  g1 |- \x.e <= A -> B -| g2
check g r1@(FunT a b) r2@(LamE v e) = runCheck "-->I" g r1 r2 $ do
  -- define x:A
  let ann = AnnG (VarE v) a
  -- check that e has the expected output type
  (g', t') <- check (g +> ann) b e
  -- ignore the trailing context and (x:A), since it is out of scope
  g2 <- cut ann g'
  return (g2, t')
--  g1,x |- e <= A -| g2,x,g3
-- ----------------------------------------- Forall.I
--  g1 |- e <= Forall x.A -| g2
check g1 r1@(Forall x a) e = runCheck "Forall.I" g1 r1 e $ do
  (g', t') <- check (g1 +> VarG x) a e
  g2 <- cut (VarG x) g'
  return (g2, t')
--  g1 |- e => A -| g2
--  g2 |- [g2]A <: [g2]B -| g3
-- ----------------------------------------- Sub
--  g1 |- e <= B -| g3
check g1 b e = runCheck "Sub" g1 b e $ do
  (g2, a) <- infer g1 e
  g3 <- subtype (apply g2 a) (apply g2 b) g2
  return (g3, apply g3 a)

derive :: Gamma -> Expr -> Type -> Stack (Gamma, Type)
--  g1 |- e <= A -| g2
-- ----------------------------------------- -->App
--  g1 |- A->C o e =>> C -| g2
derive g e t@(FunT a _) = runDerive "-->App" g e t $ do
  check g a e
--  g1,Ea |- [Ea/a]A o e =>> C -| g2
-- ----------------------------------------- Forall App
--  g1 |- Forall x.A o e =>> C -| g2
derive g e t'@(Forall x t) = runDerive "ForallApp" g e t' $ do
  derive (g +> ExistG x) e (substitute x t)
--  g1[Ea2, Ea1, Ea=Ea1->Ea2] |- e <= Ea1 -| g2
-- ----------------------------------------- EaApp
--  g1[Ea] |- Ea o e =>> Ea2 -| g2
derive g e t'@(ExistT v) = runDerive "EaApp" g e t' $ do
  a <- newvar
  b <- newvar
  let g' = g +> a +> b +> SolvedG v (FunT a b)
  check g' a e
derive g e t = runDerive "unexpected" g e t $ do
  throwError NonFunctionDerive

{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE DeriveDataTypeable #-}

#ifndef MIN_VERSION_MTL
#define MIN_VERSION_MTL(x,y,z) 1
#endif

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Monad.Trans.Iter
-- Copyright   :  (C) 2013 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  provisional
-- Portability :  MPTCs, fundeps
--
-- Based on <http://www.ioc.ee/~tarmo/tday-veskisilla/uustalu-slides.pdf Capretta's Iterative Monad Transformer>
--
-- Unlike 'Free', this is a true monad transformer.
----------------------------------------------------------------------------
module Control.Monad.Trans.Iter
  ( MonadFree(..)
  , IterF(..)
  , IterT(..)
  , delay
  , retract
  , iter
  , hoistIterT
  ) where

import Control.Applicative
import Control.Monad (ap, liftM, MonadPlus(..))
import Control.Monad.Fix
import Control.Monad.Trans.Class
import Control.Monad.Free.Class
import Control.Monad.State.Class
import Control.Monad.Reader.Class
import Data.Bifoldable
import Data.Bifunctor
import Data.Bitraversable
import Data.Functor.Bind
import Data.Functor.Identity
import Data.Foldable
import Data.Monoid
import Data.Traversable
import Data.Semigroup.Foldable
import Data.Semigroup.Traversable
import Data.Typeable

#ifdef GHC_TYPEABLE
import Data.Data
#endif

data IterF a b = Pure a | Iter b
  deriving (Eq,Ord,Show,Read,Typeable)

instance Functor (IterF a) where
  fmap _ (Pure a) = Pure a
  fmap f (Iter b) = Iter (f b)

instance Foldable (IterF a) where
  foldMap f (Iter b) = f b
  foldMap _ _         = mempty

instance Traversable (IterF a) where
  traverse _ (Pure a) = pure (Pure a)
  traverse f (Iter b) = Iter <$> f b

instance Bifunctor IterF where
  bimap f _ (Pure a) = Pure (f a)
  bimap _ g (Iter b) = Iter (g b)

instance Bifoldable IterF where
  bifoldMap f _ (Pure a) = f a
  bifoldMap _ g (Iter b) = g b

instance Bitraversable IterF where
  bitraverse f _ (Pure a) = Pure <$> f a
  bitraverse _ g (Iter b) = Iter <$> g b

iterF :: (a -> r) -> (b -> r) -> IterF a b -> r
iterF f _ (Pure a) = f a
iterF _ g (Iter b) = g b
{-# INLINE iterF #-}

-- | The monad supporting iteration based over a base monad @m@.
--
-- @
-- 'IterT' ~ 'FreeT' 'Identity'
-- @
data IterT m a = IterT { runIterT :: m (IterF a (IterT m a)) }
#if __GLASGOW_HASKELL__ >= 707
  deriving (Typeable)
#endif

instance Eq (m (IterF a (IterT m a))) => Eq (IterT m a) where
  IterT m == IterT n = m == n

instance Ord (m (IterF a (IterT m a))) => Ord (IterT m a) where
  compare (IterT m) (IterT n) = compare m n

instance Show (m (IterF a (IterT m a))) => Show (IterT m a) where
  showsPrec d (IterT m) = showParen (d > 10) $
    showString "IterT " . showsPrec 11 m

instance Read (m (IterF a (IterT m a))) => Read (IterT m a) where
  readsPrec d =  readParen (d > 10) $ \r ->
    [ (IterT m,t) | ("IterT",s) <- lex r, (m,t) <- readsPrec 11 s]

instance Monad m => Functor (IterT m) where
  fmap f = IterT . liftM (bimap f (fmap f)) . runIterT
  {-# INLINE fmap #-}

instance Monad m => Applicative (IterT m) where
  pure = IterT . return . Pure
  {-# INLINE pure #-}
  (<*>) = ap
  {-# INLINE (<*>) #-}

instance Monad m => Monad (IterT m) where
  return = IterT . return . Pure
  {-# INLINE return #-}
  IterT m >>= k = IterT $ m >>= iterF (runIterT . k) (return . Iter . (>>= k))
  {-# INLINE (>>=) #-}
  fail = IterT . fail
  {-# INLINE fail #-}

instance Monad m => Apply (IterT m) where
  (<.>) = ap
  {-# INLINE (<.>) #-}

instance Monad m => Bind (IterT m) where
  (>>-) = (>>=)
  {-# INLINE (>>-) #-}

instance MonadFix m => MonadFix (IterT m) where
  mfix f = IterT $ mfix (runIterT . f . unPure) where
    unPure (Pure x)  = x
    unPure (Iter _) = error "mfix (IterT m): Iter"
  {-# INLINE mfix #-}

instance MonadPlus m => Alternative (IterT m) where
  empty = IterT mzero
  {-# INLINE empty #-}
  IterT a <|> IterT b = IterT (mplus a b)
  {-# INLINE (<|>) #-}

instance MonadPlus m => MonadPlus (IterT m) where
  mzero = IterT mzero
  {-# INLINE mzero #-}
  IterT a `mplus` IterT b = IterT (mplus a b)
  {-# INLINE mplus #-}

-- | This is not a true monad transformer. It is only a monad transformer \"up to 'retract'\".
instance MonadTrans IterT where
  lift = IterT . liftM Pure
  {-# INLINE lift #-}

instance Foldable m => Foldable (IterT m) where
  foldMap f = foldMap (iterF f (foldMap f)) . runIterT
  {-# INLINE foldMap #-}

instance Foldable1 m => Foldable1 (IterT m) where
  foldMap1 f = foldMap1 (iterF f (foldMap1 f)) . runIterT
  {-# INLINE foldMap1 #-}

instance (Monad m, Traversable m) => Traversable (IterT m) where
  traverse f (IterT m) = IterT <$> traverse (bitraverse f (traverse f)) m
  {-# INLINE traverse #-}

instance (Monad m, Traversable1 m) => Traversable1 (IterT m) where
  traverse1 f (IterT m) = IterT <$> traverse1 go m where
    go (Pure a) = Pure <$> f a
    go (Iter a) = Iter <$> traverse1 f a
  {-# INLINE traverse1 #-}

{-
instance MonadWriter e m => MonadWriter e (IterT m) where
  tell = lift . tell
  {-# INLINE tell #-}
  listen = lift . listen . retract
  {-# INLINE listen #-}
  pass = lift . pass . retract
  {-# INLINE pass #-}
-}

instance (Functor m, MonadReader e m) => MonadReader e (IterT m) where
  ask = lift ask
  {-# INLINE ask #-}
  local f = hoistIterT (local f)
  {-# INLINE local #-}

instance (Functor m, MonadState s m) => MonadState s (IterT m) where
  get = lift get
  {-# INLINE get #-}
  put s = lift (put s)
  {-# INLINE put #-}
#if MIN_VERSION_mtl(2,1,1)
  state f = lift (state f)
  {-# INLINE state #-}
#endif

{-
instance (Functor m, MonadError e m) => MonadError e (Free m) where
  throwError = lift . throwError
  {-# INLINE throwError #-}
  catchError as f = lift (catchError (retract as) (retract . f))
  {-# INLINE catchError #-}

instance (Functor m, MonadCont m) => MonadCont (Free m) where
  callCC f = lift (callCC (retract . f . liftM lift))
  {-# INLINE callCC #-}
-}

instance Monad m => MonadFree Identity (IterT m) where
  wrap = IterT . return . Iter . runIdentity
  {-# INLINE wrap #-}

delay :: (Monad f, MonadFree f m) => m a -> m a
delay = wrap . return
{-# INLINE delay #-}

-- |
-- 'retract' is the left inverse of 'lift'
--
-- @
-- 'retract' . 'lift' = 'id'
-- @
retract :: Monad m => IterT m a -> m a
retract m = runIterT m >>= iterF return retract

-- | Tear down a 'Free' 'Monad' using iteration.
iter :: Monad m => (m a -> a) -> IterT m a -> a
iter phi (IterT m) = phi (iterF id (iter phi) `liftM` m)

-- | Lift a monad homomorphism from @m@ to @n@ into a Monad homomorphism from @'IterT' m@ to @'IterT' n@.
hoistIterT :: Monad n => (forall a. m a -> n a) -> IterT m b -> IterT n b
hoistIterT f (IterT as) = IterT (fmap (hoistIterT f) `liftM` f as)

#if defined(GHC_TYPEABLE) && __GLASGOW_HASKELL__ < 707
instance Typeable1 m => Typeable1 (IterT m) where
  typeOf1 t = mkTyConApp freeTyCon [typeOf1 (f t)] where
    f :: IterT m a -> m a
    f = undefined

freeTyCon :: TyCon
#if __GLASGOW_HASKELL__ < 704
freeTyCon = mkTyCon "Control.Monad.Iter.IterT"
#else
freeTyCon = mkTyCon3 "free" "Control.Monad.Iter" "IterT"
#endif
{-# NOINLINE freeTyCon #-}

instance
  ( Typeable1 m, Typeable a
  , Data (m (IterF a (IterT m a)))
  , Data a
  ) => Data (IterT m a) where
    gfoldl f z (IterT as) = z IterT `f` as
    toConstr IterT{} = iterConstr
    gunfold k z c = case constrIndex c of
        1 -> k (z IterT)
        _ -> error "gunfold"
    dataTypeOf _ = iterDataType
    dataCast1 f  = gcast1 f

iterConstr :: Constr
iterConstr = mkConstr iterDataType "IterT" [] Prefix
{-# NOINLINE iterConstr #-}

iterDataType :: DataType
iterDataType = mkDataType "Control.Monad.Iter.IterT" [iterConstr]
{-# NOINLINE iterDataType #-}

#endif
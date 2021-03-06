-- A module which allows halting or continuing of Monadic actions based on
-- the values within the Monads.
-- Can this be taken over by MonadPlus?

module Zero where

import System.Exit(ExitCode(..))

-- A type that is part of the Zero class must define two functions:
-- `zero` which returns its `most null` or `most plain` value.
-- `isZero` which tests if a given value is its type's `zero` value.
class Zero a where
    zero :: a
    isZero :: a -> Bool
    --isZero = zeroDefault  -- How do you define a default function?

instance Zero Int where
    zero = 0
    isZero = zeroDefault

instance Zero (Maybe a) where
    zero = Nothing
    isZero Nothing  = True
    isZero (Just _) = False

instance Zero [a] where
    zero = []
    isZero = null

instance Zero () where
    zero = ()
    isZero = zeroDefault

instance Zero Char where
    zero = '\NUL'  -- Is there a better value for this?
    isZero = zeroDefault    

instance Zero Bool where
    zero = False
    isZero = zeroDefault

instance Zero ExitCode where
    zero = ExitFailure 1
    isZero (ExitFailure _) = True
    isZero _               = False

instance (Zero a) => Zero (Either a b) where
    zero = Left zero
    isZero (Left _)  = True
    isZero (Right _) = False

zeroDefault :: (Eq a, Zero a) => a -> Bool
zeroDefault x = x == zero

{-
 Allows monadic functions to fail immediately if the result of
 one action is its `zero` value.

 Made infix 2 since (>>) and (>>=) are infix 1, thus the following
 are equivalent:

 action ?>>= action >>= action
 action ?>>= (action >>= action)
-}
infixr 2 ?>>
(?>>) :: (Monad m, Zero a, Zero b) => m a -> m b -> m b
m1 ?>> m2 = m1 >>= \x -> if isZero x then return zero else m2

infixr 2 ?>>=
(?>>=) :: (Monad m, Zero a, Zero b) => m a -> (a -> m b) -> m b
m1 ?>>= m2 = m1 >>= \x -> if isZero x then return zero else m2 x

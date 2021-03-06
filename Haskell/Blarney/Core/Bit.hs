{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE MultiParamTypeClasses #-}

{-|
Module      : Blarney.Core.Bit
Description : Typed bit-vectors and circuit primitives
Copyright   : (c) Matthew Naylor, 2019
              (c) Alexandre Joannou, 2019
License     : MIT
Maintainer  : mattfn@gmail.com
Stability   : experimental

This module provides size-typed bit vectors and circuit primitives,
on top of Blarney's untyped bit vectors and circuit primitives.
Hardware developers should always use the typed versions!
-}
module Blarney.Core.Bit where

-- Untyped bit-vectors
import Blarney.Core.BV

-- Utils
import Blarney.Core.Prim
import Blarney.Core.Utils

-- Standard imports
import Prelude
import GHC.TypeLits
import Data.Proxy

-- * Typed bit-vectors

-- |Phantom type wrapping an untyped bit vector,
-- capturing the bit-vector width.  All bit vectors
-- are members of the 'Num' and 'Cmp' classes.
newtype Bit (n :: Nat) = FromBV { toBV :: BV }

-- |Determine width of bit-vector from type
widthOf :: KnownNat n => Bit n -> Int
widthOf v = fromInteger (natVal v)

-- |Determine width of bit-vector from underlying 'BV'
unsafeWidthOf :: Bit n -> Int
unsafeWidthOf = bvPrimOutWidth . toBV

-- |Convert type Nat to Ingeter value
valueOf :: forall n. (KnownNat n) => Int
valueOf = fromInteger (natVal @n Proxy)

-- |Constant bit-vector
constant :: KnownNat n => Integer -> Bit n
constant i = result
  where
    result = FromBV $ constBV w i
    w = widthOf result

-- | Give a name to a 'Bit n' signal
nameBit :: String -> Bit n -> Bit n
nameBit nm = FromBV . (flip addBVNameHint $ NmRoot 0 nm) . toBV

-- |Test plusargs
testPlusArgs :: String -> Bit 1
testPlusArgs = FromBV . testPlusArgsBV

-- |True
true :: Bit 1
true = 1

-- |False
false :: Bit 1
false = 0

-- * Bit-vector arithmetic

-- |Adder
infixl 6 .+.
(.+.) :: Bit n -> Bit n -> Bit n
a .+. b = FromBV $ addBV (toBV a) (toBV b)

-- |Subtractor
infixl 6 .-.
(.-.) :: Bit n -> Bit n -> Bit n
a .-. b = FromBV $ subBV (toBV a) (toBV b)

-- |Multiplier
infixl 7 .*.
(.*.) :: Bit n -> Bit n -> Bit n
a .*. b = FromBV $ mulBV (toBV a) (toBV b)

-- |Multiplier (full precision)
fullMul :: Bool -> Bit n -> Bit n -> Bit (2*n)
fullMul isSigned a b = FromBV $ fullMulBV isSigned (toBV a) (toBV b)

-- |Quotient
infixl 7 ./.
(./.) :: Bit n -> Bit n -> Bit n
a ./. b = FromBV $ divBV (toBV a) (toBV b)

-- |Remainder
infixl 7 .%.
(.%.) :: Bit n -> Bit n -> Bit n
a .%. b = FromBV $ modBV (toBV a) (toBV b)

-- Arithmetic
instance KnownNat n => Num (Bit n) where
  (+)         = (.+.)
  (-)         = (.-.)
  (*)         = (.*.)
  negate a    = inv a .+. 1
  abs a       = mux (a `sLT` 0) [a, negate a]
  signum a    = mux (a .==. 0) [mux (a `sLT` 0) [1, -1], 0]
  fromInteger = constant

-- * Bitwise operations on bit-vectors

-- |Bitwise invert
inv :: Bit n -> Bit n
inv = FromBV . invBV . toBV

-- |Bitwise and
infixl 7 .&.
(.&.) :: Bit n -> Bit n -> Bit n
a .&. b = FromBV $ andBV (toBV a) (toBV b)

-- |Bitwise or
infixl 5 .|.
(.|.) :: Bit n -> Bit n -> Bit n
a .|. b = FromBV $ orBV (toBV a) (toBV b)

-- |Bitwise xor
infixl 6 .^.
(.^.) :: Bit n -> Bit n -> Bit n
a .^. b = FromBV $ xorBV (toBV a) (toBV b)

-- |Shift left
infixl 8 .<<.
(.<<.) :: Bit n -> Bit m -> Bit n
a .<<. b = FromBV $ leftBV (toBV a) (toBV b)

-- |Shift right
infixl 8 .>>.
(.>>.) :: Bit n -> Bit m -> Bit n
a .>>. b = FromBV $ rightBV (toBV a) (toBV b)

-- |Arithmetic shift right
infixl 8 .>>>.
(.>>>.) :: Bit n -> Bit m -> Bit n
a .>>>. b = FromBV $ arithRightBV (toBV a) (toBV b)

-- * Bit-vector comparison primitives

-- Comparison operators
class Cmp a where
  (.<.)  :: a -> a -> Bit 1
  (.<=.) :: a -> a -> Bit 1
  (.==.) :: a -> a -> Bit 1
  (.>.)  :: a -> a -> Bit 1
  (.>=.) :: a -> a -> Bit 1
  (.!=.) :: a -> a -> Bit 1

infix 4 .<.
infix 4 .<=.
infix 4 .>=.
infix 4 .>.
infix 4 .==.
infix 4 .!=.

instance Cmp (Bit n) where
  a .<.  b = FromBV $ lessThanBV (toBV a) (toBV b)
  a .>.  b = FromBV $ lessThanBV (toBV b) (toBV a)
  a .<=. b = FromBV $ lessThanEqBV (toBV a) (toBV b)
  a .>=. b = FromBV $ lessThanEqBV (toBV b) (toBV a)
  a .==. b = FromBV $ equalBV (toBV a) (toBV b)
  a .!=. b = FromBV $ notEqualBV (toBV a) (toBV b)

-- |Signed less than
infixl 8 `sLT`
sLT :: Bit n -> Bit n -> Bit 1
sLT x y = invMSB x .<. invMSB y

-- |Signed greater than
infixl 8 `sGT`
sGT :: Bit n -> Bit n -> Bit 1
sGT x y = invMSB x .>. invMSB y

-- |Signed less than or equal
infixl 8 `sLTE`
sLTE :: Bit n -> Bit n -> Bit 1
sLTE x y = invMSB x .<=. invMSB y

-- |Signed greater than or equal
infixl 8 `sGTE`
sGTE :: Bit n -> Bit n -> Bit 1
sGTE x y = invMSB x .>=. invMSB y

-- * Bit-vector width adjustment

-- |Replicate bit
rep :: KnownNat n => Bit 1 -> Bit n
rep a = result
  where
    result = FromBV $ replicateBV wr (toBV a)
    wr = widthOf result

-- |Zero extension
zeroExtend :: (KnownNat m, n <= m) => Bit n -> Bit m
zeroExtend a = result
   where
     result = FromBV $ zeroExtendBV wr (toBV a)
     wr = widthOf result

-- |Sign extension
signExtend :: (KnownNat m, n <= m) => Bit n -> Bit m
signExtend a = result
   where
     result = FromBV $ signExtendBV wr (toBV a)
     wr = widthOf result

-- |Bit-vector concatenation
infixr 8 #
(#) :: Bit n -> Bit m -> Bit (n+m)
a # b = FromBV $ concatBV (toBV a) (toBV b)

-- |Extract most significant bits
upper :: (KnownNat m, m <= n) => Bit n -> Bit m
upper a = result
   where
     result = unsafeSlice (wa-1, wa-wr) a
     wa = unsafeWidthOf a
     wr = widthOf result

-- |Extract most significant bits
truncateLSB :: forall m n. (KnownNat m, m <= n) => Bit n -> Bit m
truncateLSB = upper

-- |Extract least significant bits
lower :: (KnownNat m, m <= n) => Bit n -> Bit m
lower a = result
   where
     result = unsafeSlice (wr-1, 0) a
     wa = unsafeWidthOf a
     wr = widthOf result

-- |Extract least significant bits
truncate :: forall m n. (KnownNat m, m <= n) => Bit n -> Bit m
truncate = lower

-- |Split bit vector
split :: KnownNat n => Bit (n+m) -> (Bit n, Bit m)
split a = (a0, a1)
  where
    wa = unsafeWidthOf a
    w0 = widthOf a0
    a0 = unsafeSlice (wa-1, wa-w0) a
    a1 = unsafeSlice (wa-w0-1, 0) a

-- |Drop most significant bits
dropBits :: forall d n. KnownNat d => Bit (d+n) -> Bit n
dropBits a = c
  where (b, c) = split a

-- |Drop least significant bits
dropBitsLSB :: forall d n. KnownNat n => Bit (n+d) -> Bit n
dropBitsLSB a = b
  where (b, c) = split a

-- |Invert most significant bit
invMSB :: Bit n -> Bit n
invMSB x = twiddle `onBitList` x
  where twiddle bs = init bs ++ [inv (last bs)]

-- * Bit-vector selection primitives

-- | Statically-typed bit selection. Use type application to specify
--   upper and lower indices.
slice :: forall (hi :: Nat) (lo :: Nat) i o.
           (KnownNat hi, KnownNat lo, (lo+o) ~ (hi+1), (hi+1) <= i, o <= i)
      => Bit i -> Bit o
slice a = unsafeSlice (valueOf @hi, valueOf @lo) a

-- | Dynamically-typed bit selection
unsafeCheckedSlice :: KnownNat m => (Int, Int) -> Bit n -> Bit m
unsafeCheckedSlice (hi, lo) a =
  case lo > hi || (hi+1-lo) /= wr of
    True -> error "Blarney: sub-range does not match bit width"
    False -> result
  where
    result = FromBV $ selectBV (hi, lo) (toBV a)
    wr = widthOf result

-- | Untyped bit selection (try to avoid!)
unsafeSlice :: (Int, Int) -> Bit n -> Bit m
unsafeSlice (hi, lo) a = FromBV $ selectBV (hi, lo) (toBV a)

-- |Statically-typed bit indexing. Use type application to specify index.
at :: forall (i :: Nat) n. (KnownNat i, (i+1) <= n)
      => Bit n -> Bit 1
at a = unsafeAt (valueOf @i) a

-- | Dynamically-typed bit indexing
unsafeAt :: Int -> Bit n -> Bit 1
unsafeAt i a =
  case i >= wa of
    True -> error ("Bit index " ++ show i ++ " out of range ["
                                ++ show (wa-1) ++ ":0]")
    False -> result
  where
    wa = unsafeWidthOf a
    result = FromBV $ selectBV (i, i) (toBV a)

-- * Bit-vector registers

-- |Register
reg :: Bit n -> Bit n -> Bit n
reg init a = FromBV $ regBV w (toBV init) (toBV a)
  where w = unsafeWidthOf init

-- |Register with enable wire
regEn :: Bit n -> Bit 1 -> Bit n -> Bit n
regEn init en a =
    FromBV $ regEnBV w (toBV init) (toBV en) (toBV a)
  where w = unsafeWidthOf init

-- * Misc. bit-vector operations

-- | Multiplexer using a selector signal to index a list of input signals.
--   Raises a circuit generation time error on empty list of inputs
mux :: Bit w -> [Bit n] -> Bit n
mux _ [] = error "cannot mux an empty list"
mux sel xs = FromBV $ muxBV (toBV sel) (toBV <$> xs)

-- |Lift integer value to type-level natural
liftNat :: Int -> (forall n. KnownNat n => Proxy n -> a) -> a
liftNat nat k =
  case someNatVal (toInteger nat) of
    Just (SomeNat (x :: Proxy n)) -> do
      k x

-- |Convert list of bits to bit vector
fromBitList :: KnownNat n => [Bit 1] -> Bit n
fromBitList xs
  | length xs == n = result
  | otherwise = error ("fromBitList: width mismatch: " ++
                          show (length xs, n))
  where
    n = widthOf result
    result = unsafeFromBitList xs

-- |Convert bit vector to list of bits
toBitList :: KnownNat n => Bit n -> [Bit 1]
toBitList vec = [unsafeAt i vec | i <- [0..n-1]]
  where n = widthOf vec

-- | Collapse a '[Bit 1]' of size n to a single 'Bit n'
unsafeFromBitList :: [Bit 1] -> Bit n
unsafeFromBitList [] = FromBV $ constBV 0 0
unsafeFromBitList bs = FromBV $ foldr1 concatBV (reverse (fmap toBV bs))

-- | Expand a single 'Bit n' to a '[Bit 1]' of size n
unsafeToBitList :: Bit n -> [Bit 1]
unsafeToBitList bs = [unsafeAt i bs | i <- [0..size-1]]
  where size = unsafeWidthOf bs

-- | Apply bit-list transformation on bit-vector
onBitList :: ([Bit 1] -> [Bit 1]) -> Bit n -> Bit n
onBitList f x
  | null list = x
  | length list /= length list' =
      error "onBitList: transformation did not preserve length"
  | otherwise = unsafeFromBitList list'
  where
    list = unsafeToBitList x
    list' = f list

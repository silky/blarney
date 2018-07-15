-- For overriding if/then/else
{-# LANGUAGE DataKinds, KindSignatures, TypeOperators,
      TypeFamilies, RebindableSyntax, MultiParamTypeClasses,
        FlexibleContexts, ScopedTypeVariables, FlexibleInstances #-}

module Blarney.RTL (
  RTL,
  Var(..), Displayable(..),
  Reg(..), makeReg, makeRegInit, makeDReg,
  Wire(..), makeWire, makeWireDefault,
  RegFile(..), makeRegFile, makeRegFileInit,
  when, whenNot, whenR, switch, (-->),
  finish, display, input, output,
  netlist
) where

import Prelude
import Blarney.Bit
import Blarney.Bits
import Blarney.Unbit
import Blarney.Prelude
import Blarney.Format
import Blarney.IfThenElse
import qualified Blarney.JList as JL
import Control.Monad hiding (when)
import Control.Monad.Fix
import GHC.TypeLits
import Data.IORef
import Data.IntMap (IntMap, findWithDefault, fromListWith)

-- Each RTL variable has a unique id
type VarId = Int

-- The RTL monad is a reader/writer/state monad
-- The state component is the next unique variable id
type RTLS = VarId

-- The writer component is a list of RTL actions
type RTLW = JL.JList RTLAction

-- RTL actions
data RTLAction =
    RTLAssign Assign
  | RTLDisplay (Bit 1, Format)
  | RTLFinish (Bit 1)
  | RTLOutput (Width, String, Unbit)
  | RTLInput (Width, String)
  | RTLRegFileCreate (String, VarId, Width, Width)
  | RTLRegFileUpdate (VarId, Bit 1, Int, Int, Unbit, Unbit)

-- The reader component is a bit defining the current condition and a
-- list of all assigments made in the RTL block.  The list of
-- assignments is obtained by circular programming, passing the
-- writer assignments from the output of the monad to the
-- reader assignments in.
type RTLR = (Bit 1, IntMap [Assign])

-- A conditional assignment
type Assign = (Bit 1, VarId, Unbit)

-- The RTL monad
newtype RTL a =
  RTL { runRTL :: RTLR -> RTLS -> (RTLS, RTLW, a) }

instance Monad RTL where
  return a = RTL (\r s -> (s, JL.Zero, a))
  m >>= f = RTL (\r s -> let (s0, w0, a) = runRTL m r s
                             (s1, w1, b) = runRTL (f a) r s0
                         in  (s1, w1 JL.++ w0, b))

instance Applicative RTL where
  pure = return
  (<*>) = ap

instance Functor RTL where
  fmap = liftM

instance MonadFix RTL where
  mfix f = RTL $ \r s ->
    let (s', w, a) = runRTL (f a) r s in (s', w, a)

get :: RTL RTLS
get = RTL (\r s -> (s, JL.Zero, s))

set :: RTLS -> RTL ()
set s' = RTL (\r s -> (s', JL.Zero, ()))

ask :: RTL RTLR
ask = RTL (\r s -> (s, JL.Zero, r))

local :: RTLR -> RTL a -> RTL a
local r m = RTL (\_ s -> runRTL m r s)

writeAssign :: Assign -> RTL ()
writeAssign w = RTL (\r s -> (s, JL.One (RTLAssign w), ()))

writeDisplay :: (Bit 1, Format) -> RTL ()
writeDisplay w = RTL (\r s -> (s, JL.One (RTLDisplay w), ()))

writeFinish :: Bit 1 -> RTL ()
writeFinish w = RTL (\r s -> (s, JL.One (RTLFinish w), ()))

writeInput :: (Width, String) -> RTL ()
writeInput w =
  RTL (\r s -> (s, JL.One (RTLInput w), ()))

writeOutput :: (Width, String, Unbit) -> RTL ()
writeOutput w =
  RTL (\r s -> (s, JL.One (RTLOutput w), ()))

writeAction :: RTLAction -> RTL ()
writeAction a =
  RTL (\r s -> (s, JL.One a, ()))

fresh :: RTL VarId
fresh = do
  v <- get
  set (v+1)
  return v

-- Mutable variables
infix 1 <==
class Var v where
  val :: Bits a => v a -> a
  (<==) :: Bits a => v a -> a -> RTL ()

-- Register variables
data Reg a =
  Reg {
    regId  :: VarId
  , regVal :: a
  }

-- Wire variables
data Wire a =
  Wire {
    wireId  :: VarId
  , wireVal :: a
  , val'    :: a
  , active  :: Bit 1
  , active' :: Bit 1
  }

-- Register assignment
instance Var Reg where
  val r = regVal r
  r <== x = do
    (cond, as) <- ask
    writeAssign (cond, regId r, unbit (pack x))

-- Wire assignment
instance Var Wire where
  val r = wireVal r
  r <== x = do
    (cond, as) <- ask
    writeAssign (cond, wireId r, unbit (pack x))

-- RTL conditional
when :: Bit 1 -> RTL () -> RTL ()
when cond a = do
  (c, as) <- ask
  local (cond .&. c, as) a

whenNot :: Bit 1 -> RTL () -> RTL ()
whenNot cond a = Blarney.RTL.when (inv cond) a

whenR :: Bit 1 -> RTL a -> RTL a
whenR cond a = do
  (c, as) <- ask
  local (cond .&. c, as) a

ifThenElseRTL :: Bit 1 -> RTL () -> RTL () -> RTL ()
ifThenElseRTL c a b =
  do (cond, as) <- ask
     local (cond .&. c, as) a
     local (cond .&. inv c, as) b

-- Overloaded if/then/else
instance IfThenElse (Bit 1) (RTL ()) where
  ifThenElse = ifThenElseRTL

-- RTL switch statement
switch :: Bits a => a -> [(a, RTL ())] -> RTL ()
switch subject alts =
  forM_ alts $ \(lhs, rhs) ->
    when (pack subject .==. pack lhs) rhs

-- Operator for switch statement alternatives
infixl 0 -->
(-->) :: a -> RTL () -> (a, RTL ())
lhs --> rhs = (lhs, rhs)

-- Create register with initial value
makeRegInit :: Bits a => a -> RTL (Reg a)
makeRegInit init =
  do v <- fresh
     (cond, assignMap) <- ask
     let as = findWithDefault [] v assignMap
     let en = orList [b | (b, _, p) <- as]
     let w = unbitWidth (unbit (pack init))
     let bit w p = Bit (p { unbitWidth = w })
     let inp = case as of
                 [(b, _, p)] -> unpack (bit w p)
                 other -> select [(b, unpack (bit w p)) | (b, _, p) <- as]
     let out = registerEn init en inp
     return (Reg v out)

-- Create register
makeReg :: Bits a => RTL (Reg a)
makeReg = makeRegInit zero

-- Create wire with given default
makeWireDefault def =
  do v <- fresh
     (cond, assignMap) <- ask
     let w = unbitWidth (unbit (pack def))
     let bit w p = Bit (p { unbitWidth = w })
     let as = findWithDefault [] v assignMap
     let some = orList [b | (b, _, p) <- as]
     let none = inv some
     let out = select ([(b, unpack (bit w p)) | (b, _, p) <- as] ++
                          [(none, def)])
     return (Wire v out (register zero out) some (reg 0 some))

-- Create wire
makeWire :: Bits a => RTL (Wire a)
makeWire = makeWireDefault zero

-- A DReg holds the assigned value only for one cycle.
-- At all other times, it has the given default value.
makeDReg :: Bits a => a -> RTL (Reg a)
makeDReg defaultVal = do
  -- Create wire with default value
  w :: Wire a <- makeWireDefault defaultVal

  -- Register the output of the wire
  r :: Reg a <- makeRegInit defaultVal

  -- Always assign to the register
  r <== val w

  -- Write to wire and read from reg
  return (Reg { regId = wireId w, regVal = regVal r })

-- RTL finish statements
finish :: RTL ()
finish = do
  (cond, as) <- ask
  writeFinish cond

-- RTL display statements
class Displayable a where
  disp :: Format -> a

instance Displayable (RTL a) where
  disp x = do
     (cond, as) <- ask
     writeDisplay (cond, x)
     return (error "Return value of 'display' should be ignored")

instance (FShow b, Displayable a) => Displayable (b -> a) where
  disp x b = disp (x <> fshow b)

display :: Displayable a => a
display = disp (Format [])

-- Register file
data RegFile a d =
  RegFile {
    (!)    :: a -> d
  , update :: a -> d -> RTL ()
  }

-- Create register file with initial contents
makeRegFileInit :: forall a d. (Bits a, Bits d) => String -> RTL (RegFile a d)
makeRegFileInit initFile = do
  -- Create regsiter file identifier
  id <- fresh

  -- Determine widths of address/data bus
  let aw = sizeOf (__ :: a)
  let dw = sizeOf (__ :: d)

  -- Record register file for netlist generation
  writeAction $ RTLRegFileCreate (initFile, id, aw, dw)

  return $
    RegFile {
      (!) = \a ->
        unpack (regFileReadPrim id dw (pack a))
    , update = \a d -> do
        (cond, as) <- ask
        writeAction $
          RTLRegFileUpdate (id, cond, aw, dw, unbit (pack a), unbit (pack d))
    }

-- Uninitialised version
makeRegFile :: forall a d. (Bits a, Bits d) => RTL (RegFile a d)
makeRegFile = makeRegFileInit ""

-- RTL external input declaration
input :: KnownNat n => String -> RTL (Bit n)
input str = do
  let b = inputPrim str
  let u = unbit b
  writeInput (fromInteger (natVal b), str)
  return b

-- RTL external output declaration
output :: String -> Bit n -> RTL ()
output str v = do
  let u = unbit v
  writeOutput (unbitWidth u, str, u)

-- Add display primitive to netlist
addDisplayPrim :: (Bit 1, [FormatItem]) -> Flatten ()
addDisplayPrim (cond, items) = do
    c <- flatten (unbit cond)
    ins <- mapM flatten [b | FormatBit w b <- items]
    id <- freshId
    let net = Net {
                  netPrim = Display args
                , netInstId = id
                , netInputs = c:ins
                , netOutputWidths = []
              }
    addNet net
  where
    args = map toDisplayArg items
    toDisplayArg (FormatString s) = DisplayArgString s
    toDisplayArg (FormatBit w b) = DisplayArgBit w

-- Add finish primitive to netlist
addFinishPrim :: Bit 1 -> Flatten ()
addFinishPrim cond = do
  c <- flatten (unbit cond)
  id <- freshId
  let net = Net {
                netPrim = Finish
              , netInstId = id
              , netInputs = [c]
              , netOutputWidths = []
            }
  addNet net

-- Add output primitive to netlist
addOutputPrim :: (Width, String, Unbit) -> Flatten ()
addOutputPrim (w, str, value) = do
  c <- flatten value
  id <- freshId
  let net = Net {
                netPrim = Output w str
              , netInstId = id
              , netInputs = [c]
              , netOutputWidths = []
            }
  addNet net

-- Add input primitive to netlist
addInputPrim :: (Width, String) -> Flatten ()
addInputPrim (w, str) = do
  id <- freshId
  let net = Net {
                netPrim = Input w str
              , netInstId = id
              , netInputs = []
              , netOutputWidths = [w]
            }
  addNet net

-- Add RegFile primitives to netlist
addRegFilePrim :: (String, VarId, Width, Width) -> Flatten ()
addRegFilePrim (initFile, regFileId, aw, dw) = do
  id <- freshId
  let net = Net {
                netPrim = RegFileMake initFile aw dw regFileId
              , netInstId = id
              , netInputs = []
              , netOutputWidths = []
            }
  addNet net

-- Add RegFile primitives to netlist
addRegFileUpdatePrim :: (VarId, Bit 1, Int, Int, Unbit, Unbit) -> Flatten ()
addRegFileUpdatePrim (regFileId, c, aw, dw, a, d) = do
  cf <- flatten (unbit c)
  af <- flatten a
  df <- flatten d
  id <- freshId
  let net = Net {
                netPrim = RegFileWrite aw dw regFileId
              , netInstId = id
              , netInputs = [cf, af, df]
              , netOutputWidths = []
            }
  addNet net

-- Convert RTL monad to a netlist
netlist :: RTL () -> IO [Net]
netlist rtl = do
  i <- newIORef (0 :: Int)
  (nl, _) <- runFlatten roots i
  return (JL.toList nl)
  where
    (_, actsJL, _) = runRTL rtl (1, assignMap) 0
    acts = JL.toList actsJL
    assignMap = fromListWith (++) [(v, [a]) | RTLAssign a@(_, v,_) <- acts]
    disps = reverse [(go, items) | RTLDisplay (go, Format items) <- acts]
    fins  = [go | RTLFinish go <- acts]
    outs  = [out | RTLOutput out <- acts]
    inps  = [out | RTLInput out <- acts]
    rfs   = [out | RTLRegFileCreate out <- acts]
    rfus  = [out | RTLRegFileUpdate out <- acts]
    roots = do mapM_ addDisplayPrim disps
               mapM_ addFinishPrim fins
               mapM_ addOutputPrim outs
               mapM_ addInputPrim inps
               mapM_ addRegFilePrim rfs
               mapM_ addRegFileUpdatePrim rfus

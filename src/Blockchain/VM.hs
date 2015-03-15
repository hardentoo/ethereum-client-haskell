{-# LANGUAGE OverloadedStrings #-}

module Blockchain.VM (
  runCodeFromStart,
  call,
  create
  ) where

import Prelude hiding (LT, GT, EQ)

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans
import Control.Monad.Trans.Either
import Control.Monad.Trans.State
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char
import Data.Function
import Data.Functor
import Data.List
import Data.Maybe
import Data.Time.Clock.POSIX
import Numeric
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import qualified Blockchain.Colors as CL
import Blockchain.Context
import Blockchain.Data.Address
import Blockchain.Data.AddressState
import Blockchain.Data.Block
import Blockchain.Data.Code
import Blockchain.Data.Log
import Blockchain.Data.RLP
import Blockchain.Database.MerklePatricia
import Blockchain.DB.CodeDB
import Blockchain.DB.ModifyStateDB
import Blockchain.DBM
import Blockchain.ExtDBs
import Blockchain.ExtWord
import Blockchain.Format
import Blockchain.SHA
import Blockchain.Util
import Blockchain.VM.Code
import Blockchain.VM.Environment
import Blockchain.VM.Memory
import Blockchain.VM.Opcodes
import Blockchain.VM.OpcodePrices
import Blockchain.VM.PrecompiledContracts
import Blockchain.VM.VMM
import Blockchain.VM.VMState
import qualified Data.NibbleString as N


--import Debug.Trace
import Blockchain.Debug

bool2Word256::Bool->Word256
bool2Word256 True = 1
bool2Word256 False = 0

{-
word2562Bool::Word256->Bool
word2562Bool 1 = True
word2562Bool _ = False
-}

binaryAction::(Word256->Word256->Word256)->VMM ()
binaryAction action = do
  x <- pop
  y <- pop
  push $ x `action` y

unaryAction::(Word256->Word256)->VMM ()
unaryAction action = do
  x <- pop
  push $ action x

pushEnvVar::Word256Storable a=>(Environment->a)->VMM ()
pushEnvVar f = do
  VMState{environment=env} <- lift get
  push $ f env

pushVMStateVar::Word256Storable a=>(VMState->a)->VMM ()
pushVMStateVar f = do
  state' <- lift get::VMM VMState
  push $ f state'

logN::Int->VMM ()
logN n = do
  offset <- pop
  theSize <- pop
  owner <- getEnvVar envOwner
  topics' <- sequence $ replicate n pop
  
  theData <- mLoadByteString offset theSize
  addLog Log{address=owner, bloom=0, logData=theData, topics=topics'}



dupN::Int->VMM ()
dupN n = do
  stack' <- lift $ fmap stack get
  if length stack' < n
    then do
    left StackTooSmallException
    else push $ stack' !! (n-1)


s256ToInteger::Word256->Integer
--s256ToInteger i | i < 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF = toInteger i
s256ToInteger i | i < 0x8000000000000000000000000000000000000000000000000000000000000000 = toInteger i
s256ToInteger i = toInteger i - 0x10000000000000000000000000000000000000000000000000000000000000000


swapn::Int->VMM ()
swapn n = do
  v1 <- pop
  vmState <- lift get
  if length (stack vmState) < n
    then do
      left StackTooSmallException 
    else do
      let (middle, v2:rest2) = splitAt (n-1) $ stack vmState
      lift $ put vmState{stack = v2:(middle++(v1:rest2))}

getByte::Word256->Word256->Word256
getByte whichByte val | whichByte < 32 = val `shiftR` (8*(31 - fromIntegral whichByte)) .&. 0xFF
getByte _ _ = 0;

signExtend::Word256->Word256->Word256
signExtend numBytes val | numBytes > 31 = val
signExtend numBytes val = baseValue + if highBitSet then highFilter else 0
  where
    lowFilter = 2^(8*numBytes+8)-1
    highFilter = (2^(256::Integer)-1) - lowFilter
    baseValue = lowFilter .&. val
    highBitSet =  val `shiftR` (8*fromIntegral numBytes + 7) .&. 1 == 1

safe_quot::Integral a=>a->a->a
safe_quot _ 0 = 0
safe_quot x y = x `quot` y

safe_mod::Integral a=>a->a->a
safe_mod _ 0 = 0
safe_mod x y = x `mod` y

safe_rem::Integral a=>a->a->a
safe_rem _ 0 = 0
safe_rem x y = x `rem` y


--TODO- This really should be in its own monad!
--The monad should manage everything in the VM and environment (extending the ContextM), and have pop and push operations, perhaps even automating pc incrementing, gas charges, etc.
--The code would simplify greatly, but I don't feel motivated to make the change now since things work.

runOperation::Operation->VMM ()
runOperation STOP = do
  vmState <- lift get
  lift $ put vmState{done=True}

runOperation ADD = binaryAction (+)
runOperation MUL = binaryAction (*)
runOperation SUB = binaryAction (-)
runOperation DIV = binaryAction safe_quot
runOperation SDIV = binaryAction ((fromIntegral .) . safe_quot `on` s256ToInteger)
runOperation MOD = binaryAction safe_mod
runOperation SMOD = binaryAction ((fromIntegral .) . safe_rem `on` s256ToInteger) --EVM mod corresponds to Haskell rem....  mod and rem only differ in how they handle negative numbers

runOperation ADDMOD = do
  v1 <- pop::VMM Word256
  v2 <- pop::VMM Word256
  modVal <- pop::VMM Word256

  push $ (toInteger v1 + toInteger v2) `safe_mod` toInteger modVal

runOperation MULMOD = do
  v1 <- pop::VMM Word256
  v2 <- pop::VMM Word256
  modVal <- pop::VMM Word256

  let ret = (toInteger v1 * toInteger v2) `safe_mod` toInteger modVal
  push ret


runOperation EXP = binaryAction (^)
runOperation SIGNEXTEND = binaryAction signExtend



runOperation NEG = unaryAction negate
runOperation LT = binaryAction ((bool2Word256 .) . (<))
runOperation GT = binaryAction ((bool2Word256 .) . (>))
runOperation SLT = binaryAction ((bool2Word256 .) . ((<) `on` s256ToInteger))
runOperation SGT = binaryAction ((bool2Word256 .) . ((>) `on` s256ToInteger))
runOperation EQ = binaryAction ((bool2Word256 .) . (==))
runOperation ISZERO = unaryAction (bool2Word256 . (==0))
runOperation AND = binaryAction (.&.)
runOperation OR = binaryAction (.|.)
runOperation XOR = binaryAction xor

runOperation NOT = unaryAction (0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF `xor`)

runOperation BYTE = binaryAction getByte

runOperation SHA3 = do
  p <- pop
  size <- pop
  theData <- mLoadByteString p size
  let SHA theHash = hash theData
  push $ theHash

runOperation ADDRESS = pushEnvVar envOwner

runOperation BALANCE = do
  x <- pop
  addressState <- lift $ lift $ lift $ getAddressState x
  push $ balance addressState

runOperation ORIGIN = pushEnvVar envOrigin
runOperation CALLER = pushEnvVar envSender
runOperation CALLVALUE = pushEnvVar envValue

runOperation CALLDATALOAD = do
  p <- pop
  d <- getEnvVar envInputData

  let val = bytes2Integer $ appendZerosTo32 $ B.unpack $ B.take 32 $ safeDrop p $ d
  push val
    where
      appendZerosTo32 x | length x < 32 = x ++ replicate (32-length x) 0
      appendZerosTo32 x = x
      
runOperation CALLDATASIZE = pushEnvVar (B.length . envInputData)

runOperation CALLDATACOPY = do
  memP <- pop
  codeP <- pop
  size <- pop
  d <- getEnvVar envInputData
  
  mStoreByteString memP $ safeTake size $ safeDrop codeP $ d

runOperation CODESIZE = pushEnvVar (codeLength . envCode)

runOperation CODECOPY = do
  memP <- pop
  codeP <- pop
  size <- pop
  Code c <- getEnvVar envCode
  
  mStoreByteString memP $ safeTake size $ safeDrop codeP $ c

runOperation GASPRICE = pushEnvVar envGasPrice


runOperation EXTCODESIZE = do
  address' <- pop
  addressState <- lift $ lift $ lift $ getAddressState address'
  code <- lift $ lift $ lift $ fromMaybe B.empty <$> getCode (codeHash addressState)
  push $ (fromIntegral (B.length code)::Word256)

runOperation EXTCODECOPY = do
  address' <- pop
  memOffset <- pop
  codeOffset <- pop
  size <- pop
  
  addressState <- lift $ lift $ lift $ getAddressState address'
  code <- lift $ lift $ lift $ fromMaybe B.empty <$> getCode (codeHash addressState)
  mStoreByteString memOffset (safeTake size $ safeDrop codeOffset $ code)
  push $ (fromIntegral (B.length code)::Word256)

runOperation BLOCKHASH = do
  number' <- pop::VMM Word256
  block <- getEnvVar envBlock
  
  let SHA h = hash $ BC.pack $ show $ toInteger number'

  let blockNumber = number (blockData block)
      
  if toInteger number' >= blockNumber || toInteger number' < blockNumber - 256
    then push (0::Word256)
    else push h

runOperation COINBASE = pushEnvVar (coinbase . blockData . envBlock)
runOperation TIMESTAMP = do
  VMState{environment=env} <- lift get
  push $ ((round . utcTimeToPOSIXSeconds . timestamp . blockData . envBlock) env::Word256)


  
runOperation NUMBER = pushEnvVar (number . blockData . envBlock)
runOperation DIFFICULTY = pushEnvVar (difficulty . blockData . envBlock)
runOperation GASLIMIT = pushEnvVar (gasLimit . blockData . envBlock)

runOperation POP = do
  _ <- pop::VMM Word256
  return ()

runOperation LOG0 = logN 0
runOperation LOG1 = logN 1
runOperation LOG2 = logN 2
runOperation LOG3 = logN 3
runOperation LOG4 = logN 4

runOperation MLOAD = do
  p <- pop
  bytes <- mLoad p
  push $ (fromInteger (bytes2Integer bytes)::Word256)
  
runOperation MSTORE = do
  p <- pop
  val <- pop
  mStore p val

runOperation MSTORE8 = do
  p <- pop
  val <- pop::VMM Word256
  mStore8 p (fromIntegral $ val .&. 0xFF)

runOperation SLOAD = do
  p <- pop
  vals <- lift $ lift $ lift $ getStorageKeyVals (N.pack $ (N.byte2Nibbles =<<) $ word256ToBytes p)
  let val = case vals of
              [] -> 0::Word256
              [x] -> fromInteger $ rlpDecode $ rlpDeserialize $ rlpDecode $ snd x
              _ -> error "Multiple values in storage"

  push val
  
runOperation SSTORE = do
  p <- pop
  val <- pop
  if val == 0
    then lift $ lift $ lift $ deleteStorageKey (N.pack $ (N.byte2Nibbles =<<) $ word256ToBytes p)
    else lift $ lift $ lift $ putStorageKeyVal p val

--TODO- refactor so that I don't have to use this -1 hack
runOperation JUMP = do
  p <- pop
  jumpDests <- getEnvVar envJumpDests

  if p `elem` jumpDests
    then setPC $ fromIntegral p - 1 -- Subtracting 1 to compensate for the pc-increment that occurs every step.
    else left InvalidJump

runOperation JUMPI = do
  p <- pop
  cond <- pop
  jumpDests <- getEnvVar envJumpDests
  
  case (p `elem` jumpDests, (0::Word256) /= cond) of
    (_, False) -> return ()
    (True, _) -> setPC $ fromIntegral p - 1
    _ -> left InvalidJump
  
runOperation PC = pushVMStateVar pc

runOperation MSIZE = do
  memSize <- getSizeInBytes
  push memSize

runOperation GAS = pushVMStateVar vmGasRemaining

runOperation JUMPDEST = return ()

runOperation (PUSH vals) =
  push $ (fromIntegral (bytes2Integer vals)::Word256)

runOperation DUP1 = dupN 1
runOperation DUP2 = dupN 2
runOperation DUP3 = dupN 3
runOperation DUP4 = dupN 4
runOperation DUP5 = dupN 5
runOperation DUP6 = dupN 6
runOperation DUP7 = dupN 7
runOperation DUP8 = dupN 8
runOperation DUP9 = dupN 9
runOperation DUP10 = dupN 10
runOperation DUP11 = dupN 11
runOperation DUP12 = dupN 12
runOperation DUP13 = dupN 13
runOperation DUP14 = dupN 14
runOperation DUP15 = dupN 15
runOperation DUP16 = dupN 16

runOperation SWAP1 = swapn 1
runOperation SWAP2 = swapn 2
runOperation SWAP3 = swapn 3
runOperation SWAP4 = swapn 4
runOperation SWAP5 = swapn 5
runOperation SWAP6 = swapn 6
runOperation SWAP7 = swapn 7
runOperation SWAP8 = swapn 8
runOperation SWAP9 = swapn 9
runOperation SWAP10 = swapn 10
runOperation SWAP11 = swapn 11
runOperation SWAP12 = swapn 12
runOperation SWAP13 = swapn 13
runOperation SWAP14 = swapn 14
runOperation SWAP15 = swapn 15
runOperation SWAP16 = swapn 16

runOperation CREATE = do
  value <- pop::VMM Word256
  input <- pop
  size <- pop

  owner <- getEnvVar envOwner
  block <- getEnvVar envBlock

  initCodeBytes <- mLoadByteString input size

  vmState <- lift get

  result <-
    case debugCallCreates vmState of
      Nothing -> create_debugWrapper block owner value initCodeBytes
      Just _ -> do
        addressState <- lift $ lift $ lift $ getAddressState owner
        let newAddress = getNewAddress owner (addressStateNonce addressState)

        addressState' <- lift $ lift $ lift $ getAddressState owner
        
        if balance addressState' < fromIntegral value
          then return Nothing
          else do
          addToBalance' owner (-fromIntegral value)
          addDebugCallCreate DebugCallCreate {
            ccData=initCodeBytes,
            ccDestination=Nothing,
            ccGasLimit=vmGasRemaining vmState,
            ccValue=fromIntegral value
            }
          return $ Just newAddress

  case result of
    Just address' -> push address'
    Nothing -> push (0::Word256)

runOperation CALL = do
  gas <- pop::VMM Word256
  to <- pop
  value <- pop::VMM Word256
  inOffset <- pop
  inSize <- pop
  outOffset <- pop
  outSize <- pop::VMM Word256

  owner <- getEnvVar envOwner
  sender <- getEnvVar envSender

  inputData <- mLoadByteString inOffset inSize

  vmState <- lift get

  toAddressExists <- lift $ lift $ lift $ addressStateExists to

  let newAccountCost = if not toAddressExists then gCALLNEWACCOUNT else 0

  let stipend = if value > 0 then gCALLSTIPEND  else 0

  useGas $ fromIntegral newAccountCost

  (result, maybeBytes) <-
    case debugCallCreates vmState of
      Nothing -> do
        pay' "nestedRun fees" owner to (fromIntegral value)
        nestedRun_debugWrapper (gas + stipend) to sender value inputData 
      Just _ -> do
        addGas $ fromIntegral stipend
        addToBalance' owner (-fromIntegral value)
        addGas $ fromIntegral gas
        addDebugCallCreate DebugCallCreate {
          ccData=inputData,
          ccDestination=Just to,
          ccGasLimit=fromIntegral (gas + stipend),
          ccValue=fromIntegral value
          }
        return (1, Nothing)

  case maybeBytes of
    Nothing -> return ()
    Just bytes -> mStoreByteString outOffset bytes
  
  push result

runOperation CALLCODE = do

  gas <- pop::VMM Word256
  to <- pop
  value <- pop::VMM Word256
  inOffset <- pop
  inSize <- pop
  outOffset <- pop
  outSize <- pop::VMM Word256

  owner <- getEnvVar envOwner
  sender <- getEnvVar envSender

  inputData <- mLoadByteString inOffset inSize

  vmState <- lift get

  addToBalance' owner (-fromIntegral value)

  let stipend = if value > 0 then gCALLSTIPEND  else 0

  toAddressExists <- lift $ lift $ lift $ addressStateExists to

  let newAccountCost = if not toAddressExists then gCALLNEWACCOUNT else 0

  (result, maybeBytes) <-
    case debugCallCreates vmState of
      Nothing -> nestedRun_debugWrapper gas to sender value inputData 
      Just _ -> do
        useGas $ fromIntegral newAccountCost
        addGas $ fromIntegral stipend
        addGas $ fromIntegral gas
        addDebugCallCreate DebugCallCreate {
          ccData=inputData,
          ccDestination=Just $  owner,
          ccGasLimit=fromIntegral $ gas + stipend,
          ccValue=fromIntegral value
          }
        return (1, Nothing)

  case maybeBytes of
    Nothing -> return ()
    Just bytes -> mStoreByteString outOffset bytes
  
  push result

runOperation RETURN = do
  address' <- pop
  size <- pop
  
  retVal <- mLoadByteString address' size
  setDone True
  setReturnVal $ Just retVal

runOperation SUICIDE = do
  address' <- pop
  owner <- getEnvVar envOwner
  addressState <- lift $ lift $ lift $ getAddressState $ owner

  let allFunds = balance addressState
  pay' "transferring all funds upon suicide" owner address' allFunds
  addSuicideList owner
  setDone True


runOperation (MalformedOpcode opcode) = do
  when debug $ liftIO $ putStrLn $ CL.red ("Malformed Opcode: " ++ showHex opcode "")
  left MalformedOpcodeException

runOperation x = error $ "Missing case in runOperation: " ++ show x

-------------------

opGasPriceAndRefund::Operation->VMM (Integer, Integer)
--opGasPriceAndRefund CALL = return (20, 0)
----opGasPriceAndRefund VMState{stack=value:_} CALLCODE = return (20+fromIntegral value, 0)
--opGasPriceAndRefund CALLCODE = return (20, 0)

opGasPriceAndRefund LOG0 = do
  size <- getStackItem 1::VMM Word256
  return (gLOG + gLOGDATA * fromIntegral size, 0)
opGasPriceAndRefund LOG1 = do
  size <- getStackItem 1::VMM Word256
  return (gLOG + gLOGTOPIC + gLOGDATA * fromIntegral size, 0)
opGasPriceAndRefund LOG2 = do
  size <- getStackItem 1::VMM Word256
  return (gLOG + 2*gLOGTOPIC + gLOGDATA * fromIntegral size, 0)
opGasPriceAndRefund LOG3 = do
  size <- getStackItem 1::VMM Word256
  return (gLOG + 3*gLOGTOPIC + gLOGDATA * fromIntegral size, 0)
opGasPriceAndRefund LOG4 = do
  size <- getStackItem 1::VMM Word256
  return (gLOG + 4*gLOGTOPIC + gLOGDATA * fromIntegral size, 0)

opGasPriceAndRefund SHA3 = do
  size <- getStackItem 1::VMM Word256
  return (30+6*ceiling(fromIntegral size/(32::Double)), 0)

opGasPriceAndRefund EXP = do
    e <- getStackItem 1::VMM Word256
    if e == 0
      then return (gEXPBASE, 0)
      else return (gEXPBASE + gEXPBYTE*bytesNeeded e, 0)

    where
      bytesNeeded::Word256->Integer
      bytesNeeded 0 = 0
      bytesNeeded x = 1+bytesNeeded (x `shiftR` 8)


opGasPriceAndRefund CALL = do
  gas <- getStackItem 0::VMM Word256
  to <- getStackItem 1::VMM Word256
  val <- getStackItem 2::VMM Word256

  toAccountExists <- lift $ lift $ lift $ addressStateExists $ Address $ fromIntegral to

  return $ (fromIntegral $
                       fromIntegral gas +
                       fromIntegral gCALL +
                       (if toAccountExists || to < 5 then 0 else gCALLNEWACCOUNT) +
                       (if val > 0 then gCALLVALUETRANSFER else 0),
                0)


opGasPriceAndRefund CALLCODE = do
  gas <- getStackItem 0::VMM Word256
  to <- getStackItem 1::VMM Word256
  val <- getStackItem 2::VMM Word256

  toAccountExists <- lift $ lift $ lift $ addressStateExists $ Address $ fromIntegral to

  return $ (fromIntegral $
                fromIntegral gas +
                fromIntegral gCALL +
                (if toAccountExists then 0 else gCALLNEWACCOUNT) +
                (if val > 0 then gCALLVALUETRANSFER else 0),
            0)


opGasPriceAndRefund CODECOPY = do
    size <- getStackItem 2::VMM Word256
    return (gCODECOPYBASE + gCOPYWORD * ceiling (fromIntegral size / (32::Double)), 0)
opGasPriceAndRefund CALLDATACOPY = do
    size <- getStackItem 2::VMM Word256
    return (gCALLDATACOPYBASE + gCOPYWORD * ceiling (fromIntegral size / (32::Double)), 0)
opGasPriceAndRefund EXTCODECOPY = do
    size <- getStackItem 3::VMM Word256
    return (gEXTCODECOPYBASE + gCOPYWORD * ceiling (fromIntegral size / (32::Double)), 0)
opGasPriceAndRefund SSTORE = do
  p <- getStackItem 0
  val <- getStackItem 1
  oldVals <- lift $ lift $ lift $ getStorageKeyVals (N.pack $ (N.byte2Nibbles =<<) $ word256ToBytes p)
  let oldVal =
          case oldVals of
            [] -> 0::Word256
            [x] -> fromInteger $ rlpDecode $ snd x
            _ -> error "multiple values in storage"
  case (oldVal, val) of
      (0, x) | x /= (0::Word256) -> return (20000, 0)
      (x, 0) | x /= 0 -> return (5000, 15000)
      _ -> return (5000, 0)
opGasPriceAndRefund SUICIDE = return (0, 24000)

{-opGasPriceAndRefund RETURN = do
  size <- getStackItem 1

  return (gTXDATANONZERO*size, 0)-}

opGasPriceAndRefund x = return (opGasPrice x, 0)

--missing stuff
--Glog 1 Partial payment for a LOG operation.
--Glogdata 1 Paid for each byte in a LOG operation’s data.
--Glogtopic 1 Paid for each topic of a LOG operation.

nibbleString2ByteString::N.NibbleString->B.ByteString
nibbleString2ByteString (N.EvenNibbleString s) = s
nibbleString2ByteString (N.OddNibbleString c s) = c `B.cons` s


showHex4::Word256->String
showHex4 i = replicate (4 - length rawOutput) '0' ++ rawOutput
    where rawOutput = showHex i ""

formatOp::Operation->String
formatOp (PUSH x) = "PUSH" ++ show (length x) -- ++ show x
formatOp x = show x

formatAddressWithoutColor::Address->String
formatAddressWithoutColor (Address x) = padZeros 40 $ showHex x ""

showHexU::Integer->[Char]
showHexU = map toUpper . flip showHex ""

printDebugInfo::Environment->Word256->Word256->Int->Operation->VMState->VMState->ContextM ()
printDebugInfo env memBefore memAfter c op stateBefore stateAfter = do
  liftIO $ putStrLn $ "EVM [ eth | " ++ show (callDepth stateBefore) ++ " | " ++ formatAddressWithoutColor (envOwner env) ++ " | #" ++ show c ++ " | " ++ map toUpper (showHex4 (pc stateBefore)) ++ " : " ++ formatOp op ++ " | " ++ show (vmGasRemaining stateBefore) ++ " | " ++ show (vmGasRemaining stateAfter - vmGasRemaining stateBefore) ++ " | " ++ show(toInteger memAfter - toInteger memBefore) ++ "x32 ]"
  liftIO $ putStrLn $ "EVM [ eth ] "
  memByteString <- liftIO $ getMemAsByteString (memory stateAfter)
  liftIO $ putStrLn "    STACK"
  liftIO $ putStr $ unlines (padZeros 64 <$> flip showHex "" <$> (reverse $ stack stateAfter))
  liftIO $ putStr $ "    MEMORY\n" ++ showMem 0 (B.unpack $ memByteString)
  liftIO $ putStrLn $ "    STORAGE"
  kvs <- lift $ getStorageKeyVals ""
  liftIO $ putStrLn $ unlines (map (\(k, v) -> "0x" ++ showHexU (byteString2Integer $ nibbleString2ByteString k) ++ ": 0x" ++ showHexU (rlpDecode $ rlpDeserialize $ rlpDecode v::Integer)) kvs)

runCode::Int->VMM ()
runCode c = do
  memBefore <- getSizeInWords
  code <- getEnvVar envCode

  vmState <- lift get

  let (op, len) = getOperationAt code (pc vmState)
  --liftIO $ putStrLn $ "EVM [ 19:22" ++ show op ++ " #" ++ show c ++ " (" ++ show (vmGasRemaining state) ++ ")"

  (val, theRefund) <- opGasPriceAndRefund op
  useGas val
  addToRefund theRefund

  runOperation op

  memAfter <- getSizeInWords

  result <- lift get
  when debug $ lift $ lift $ printDebugInfo (environment result) memBefore memAfter c op vmState result

  case result of
    VMState{done=True} -> incrementPC len
    _ -> do
      incrementPC len
      runCode (c+1)

runCodeFromStart::Int->VMM ()
runCodeFromStart callDepth' = do
  env <- lift $ fmap environment get

  when debug $ liftIO $ putStrLn $ "running code: " ++ tab (CL.magenta ("\n" ++ show (pretty $ envCode env)))

  addressAlreadyExists <- lift $ lift $ lift $ addressStateExists (envOwner env)

  storageRoot <-
    if addressAlreadyExists
    then do
      addressState <- lift $ lift $ lift $ getAddressState (envOwner env)
      return $ contractRoot addressState
    else return emptyTriePtr

  oldStateRoot <- lift $ lift $ lift getStorageStateRoot
  lift $ lift $ lift $ setStorageStateRoot storageRoot

  result <- 
    if callDepth' > 1024
    then left CallStackTooDeep
    else runCode 0

  newStorageStateRoot <- lift $ lift $ lift getStorageStateRoot
  ownerAddressState <- lift $ lift $ lift $ getAddressState $ envOwner env
  lift $ lift $ lift $ putAddressState (envOwner env) ownerAddressState{contractRoot=newStorageStateRoot}

  lift $ lift $ lift $ setStorageStateRoot oldStateRoot

  newVMState <- lift get

  when debug $ liftIO $ putStrLn $ "Removing accounts in suicideList: " ++ intercalate ", " (show . pretty <$> suicideList newVMState)

  forM_ (suicideList newVMState) $ lift . lift . lift . deleteAddressState

  return result


--bool Executive::create(Address _sender, u256 _endowment, u256 _gasPrice, u256 _gas, bytesConstRef _init, Address _origin)

create::Block->Int->Address->Address->Integer->Integer->Integer->Address->Code->ContextM (Either VMException Code, VMState)
create b callDepth' sender origin value' gasPrice' availableGas newAddress init' = do
  let env =
        Environment{
          envGasPrice=gasPrice',
          envBlock=b,
          envOwner = newAddress,
          envOrigin = origin,
          envInputData = B.empty,
          envSender = sender,
          envValue = value',
          envCode = init',
          envJumpDests = getValidJUMPDESTs init'
          }

  vmState <- liftIO $ startingState env

  result <-
    flip runStateT vmState{callDepth=callDepth', vmGasRemaining=availableGas} $ runEitherT $
    create' callDepth'

  when debug $ liftIO $ putStrLn "VM has finished running"

  return result



create'::Int->VMM Code
create' callDepth' = do

  runCodeFromStart callDepth'

  vmState <- lift get
  
  let result = fromMaybe B.empty $ returnVal vmState
  when debug $ liftIO $ putStrLn $ "Result: " ++ show result
  --Not sure which way this is supposed to go....  I'll keep going back and forth until I figure it out

  useGas $ 5 * toInteger (B.length result)

  lift $ lift $ lift $ addCode result

  return $ Code result

--bool Executive::call(Address _receiveAddress, Address _codeAddress, Address _senderAddress, u256 _value, u256 _gasPrice, bytesConstRef _data, u256 _gas, Address _originAddress)

call::Block->Int->Address->Address->Address->Word256->Word256->B.ByteString->Word256->Address->ContextM (Either VMException B.ByteString, VMState)
call b callDepth' receiveAddress (Address codeAddress) sender value' gasPrice' theData gas origin = do

  addressState <- lift $ getAddressState $ Address codeAddress
  code <- lift $ Code <$> fromMaybe B.empty <$> getCode (codeHash addressState)

  let env =
        Environment{
          envGasPrice=fromIntegral gasPrice',
          envBlock=b,
          envOwner = receiveAddress,
          envOrigin = origin,
          envInputData = theData,
          envSender = sender,
          envValue = fromIntegral value',
          envCode = code,
          envJumpDests = getValidJUMPDESTs code
          }

  
  nestedVMState <- liftIO $ startingState env

  result <-
    flip runStateT nestedVMState{callDepth=callDepth', vmGasRemaining=fromIntegral gas} $
    runEitherT $ do
      if codeAddress < 5
        then callPrecompiledContract codeAddress theData
        else call' callDepth'

  when debug $ liftIO $ putStrLn "VM has finished running"

  return result


--bool Executive::call(Address _receiveAddress, Address _codeAddress, Address _senderAddress, u256 _value, u256 _gasPrice, bytesConstRef _data, u256 _gas, Address _originAddress)

call'::Int->VMM B.ByteString
--call' callDepth' address codeAddress sender value' gasPrice' theData availableGas origin = do
call' callDepth' = do

  --when debug $ liftIO $ putStrLn $ "availableGas: " ++ show availableGas

  runCodeFromStart callDepth'

  vmState <- lift get

  when debug $ liftIO $ do
      let result = fromMaybe B.empty $ returnVal vmState
      putStrLn $ "Result: " ++ format result
      putStrLn $ "Gas remaining: " ++ show (vmGasRemaining vmState) ++ ", needed: " ++ show (5*toInteger (B.length result))
      --putStrLn $ show (pretty address) ++ ": " ++ format result

  return (fromMaybe B.empty $ returnVal vmState)





create_debugWrapper::Block->Address->Word256->B.ByteString->VMM (Maybe Address)
create_debugWrapper block owner value initCodeBytes = do

  addressState <- lift $ lift $ lift $ getAddressState owner
  let newAddress = getNewAddress owner (addressStateNonce addressState)

  if fromIntegral value > balance addressState
    then return Nothing
    else do
      when debug $ liftIO $ putStrLn "transfer value"
      lift $ lift $ addToBalance owner (-fromIntegral value)

      let initCode = Code initCodeBytes
      
      origin <- getEnvVar envOrigin
      gasPrice <- getEnvVar envGasPrice

      gasRemaining <- getGasRemaining

      currentCallDepth <- getCallDepth

      let newAccountState =
                AddressState {
                  addressStateNonce=0,
                  balance = fromIntegral value,
                  contractRoot = emptyTriePtr,
                  codeHash = hash B.empty
                  }

      lift $ lift $ lift $ putAddressState newAddress newAccountState
          

      (result, finalVMState) <- 
        lift $ lift $
          create block currentCallDepth owner origin (toInteger value) gasPrice gasRemaining newAddress initCode

      case result of
        Left e -> do
          liftIO $ putStrLn $ CL.red $ show e
          return Nothing
        Right (Code codeBytes') -> do

          addressState' <- lift $ lift $ lift $ getAddressState newAddress
          lift $ lift $ lift $ putAddressState newAddress addressState'{codeHash = hash codeBytes'}

          newAddressExists <- lift $ lift $ lift $ addressStateExists newAddress
          when newAddressExists $ lift $ lift $ incrementNonce owner

          setGasRemaining $ vmGasRemaining finalVMState

          return $ Just newAddress





nestedRun_debugWrapper::Word256->Address->Address->Word256->B.ByteString->VMM (Int, Maybe B.ByteString)
nestedRun_debugWrapper gas (Address address') sender value inputData = do
  
  theAddressExists <- lift $ lift $ lift $ addressStateExists (Address address')

  when (not theAddressExists && address' > 4) $ do
    left AddressDoesNotExist

  --pay' "gas payment in CALL opcode run" owner (Address to) $ fromIntegral value

  storageStateRoot <- lift $ lift $ lift getStorageStateRoot
  addressState <- lift $ lift $ lift $ getAddressState $ Address address'
  lift $ lift $ lift $ putAddressState (Address address') addressState{contractRoot=storageStateRoot}

  currentCallDepth <- getCallDepth

  env <- lift $ fmap environment $ get

  (result, finalVMState) <- 
    lift $ lift $
      call (envBlock env) currentCallDepth (Address address') (Address address') sender value (fromIntegral $ envGasPrice env) inputData gas (envOrigin env)

{-      state'' <- lift get
      --Need to load newest stateroot in case it changed recursively within the nestedRun
      --TODO- think this one out....  There should be a cleaner way to do this.  Also, I am not sure that I am passing in storage changes to the nested calls to begin with.
      addressState <- lift $ lift $ lift $ getAddressState $ Address address
      lift $ lift $ lift $ setStorageStateRoot (contractRoot addressState)
      return (state'', returnVal state'') -}
  
  case result of
        Right retVal -> do
          forM_ (reverse $ logs finalVMState) addLog
          useGas (- vmGasRemaining finalVMState)
          return (1, Just retVal)
        Left _ -> do
--          liftIO $ print (e::VMException)
          return (0, Nothing)

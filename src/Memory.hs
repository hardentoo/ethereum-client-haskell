{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
module Memory (
  Memory(..),
  newMemory,
  mLoad,
  mLoad8,
  mLoadByteString,
  mStore,
  mStore8,
  mStoreByteString
  ) where

import Data.Array.IO
import qualified Data.ByteString as B
import Data.Functor
import Data.Word

import ExtWord
import Util

data Memory = Memory Word256 (IOArray Word256 Word8)


newMemory::IO Memory
newMemory = do
  m <- newArray (0, 100) 0
  return $ Memory 0 m

mLoad::Memory->Word256->IO [Word8]
mLoad (Memory _ arr) p = sequence $ readArray arr <$> [p..p+31] 

mLoad8::Memory->Word256->IO Word8
mLoad8 (Memory _ arr) p = readArray arr p

mLoadByteString::Memory->Word256->Word256->IO B.ByteString
mLoadByteString (Memory _ arr) p size = fmap B.pack $ sequence $ readArray arr <$> [p..p+size-1] 


mStore::Memory->Word256->Word256->IO ()
mStore (Memory _ arr) p val = sequence_ $ uncurry (writeArray arr) <$> zip [p..] (word256ToBytes val)

mStore8::Memory->Word256->Word8->IO ()
mStore8 (Memory _ arr) p val = writeArray arr p val

mStoreByteString::Memory->Word256->B.ByteString->IO ()
mStoreByteString (Memory _ arr) p theData = sequence_ $ uncurry (writeArray arr) <$> zip [p..p+fromIntegral (B.length theData)] (B.unpack theData)


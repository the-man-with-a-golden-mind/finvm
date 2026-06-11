-- | A persistent chunked vector used as the backing store for VM lists.
-- |
-- | Lists in FinVM are accessed by index (LIST_GET) and grown by append
-- | (LIST_APPEND). A plain immutable Array makes append O(n) (copying the whole
-- | array each time), so building a list of n elements is O(n^2). This vector
-- | stores elements in fixed-size blocks plus a partial tail:
-- |   - index / length:      O(1)
-- |   - append (snoc):        amortized ~O(1) (copies only the small tail block,
-- |                           and the block spine only once per `blockSize` appends)
-- |   - building n elements:  ~O(n) for practical sizes
-- | Eq/Ord/Show are defined over the logical sequence so list semantics
-- | (comparison, hashing, display) are identical to the old Array backing.
module FinVM.Vec
  ( Vec
  , empty
  , fromArray
  , toArray
  , snoc
  , index
  , updateAt
  , length
  ) where

import Prelude
import Data.Array as Array
import Data.Maybe (Maybe(..))

-- Tuning: larger blocks => cheaper spine growth but pricier tail copies.
blockSize :: Int
blockSize = 256

-- Invariant: every entry of `blocks` has length `blockSize`; `tail` has length
-- in [0, blockSize); len == blockSize * (number of blocks) + length tail.
newtype Vec a = Vec { blocks :: Array (Array a), tail :: Array a, len :: Int }

empty :: forall a. Vec a
empty = Vec { blocks: [], tail: [], len: 0 }

length :: forall a. Vec a -> Int
length (Vec v) = v.len

snoc :: forall a. Vec a -> a -> Vec a
snoc (Vec v) x =
  let tail' = Array.snoc v.tail x
  in if Array.length tail' >= blockSize
     then Vec { blocks: Array.snoc v.blocks tail', tail: [], len: v.len + 1 }
     else Vec { blocks: v.blocks, tail: tail', len: v.len + 1 }

index :: forall a. Vec a -> Int -> Maybe a
index (Vec v) i =
  if i < 0 || i >= v.len then Nothing
  else
    let nb = Array.length v.blocks
        bi = i / blockSize
    in if bi < nb
       then Array.index v.blocks bi >>= \blk -> Array.index blk (i `mod` blockSize)
       else Array.index v.tail (i - nb * blockSize)

updateAt :: forall a. Int -> a -> Vec a -> Maybe (Vec a)
updateAt i x (Vec v) =
  if i < 0 || i >= v.len then Nothing
  else
    let nb = Array.length v.blocks
        bi = i / blockSize
    in if bi < nb
       then do
         blk <- Array.index v.blocks bi
         blk' <- Array.updateAt (i `mod` blockSize) x blk
         blocks' <- Array.updateAt bi blk' v.blocks
         pure (Vec v { blocks = blocks' })
       else do
         tail' <- Array.updateAt (i - nb * blockSize) x v.tail
         pure (Vec v { tail = tail' })

toArray :: forall a. Vec a -> Array a
toArray (Vec v) = Array.concat v.blocks <> v.tail

fromArray :: forall a. Array a -> Vec a
fromArray arr =
  let
    n = Array.length arr
    fullCount = n / blockSize
    go bi acc =
      if bi >= fullCount then acc
      else go (bi + 1) (Array.snoc acc (Array.slice (bi * blockSize) ((bi + 1) * blockSize) arr))
    blocks = go 0 []
    tail = Array.slice (fullCount * blockSize) n arr
  in Vec { blocks, tail, len: n }

-- Eq/Ord/Show over the logical sequence: identical observable behavior to the
-- previous `Array Value` backing (so VM list comparison/hashing is unchanged).
instance eqVec :: Eq a => Eq (Vec a) where
  eq a b = toArray a == toArray b

instance ordVec :: Ord a => Ord (Vec a) where
  compare a b = compare (toArray a) (toArray b)

instance showVec :: Show a => Show (Vec a) where
  show v = show (toArray v)

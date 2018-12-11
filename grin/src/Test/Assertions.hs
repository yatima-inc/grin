module Test.Assertions where

import Test.Hspec

import Grin.Grin
import Grin.Pretty
import Grin.TypeEnv

import AbstractInterpretation.CreatedBy.Pretty
import AbstractInterpretation.CreatedBy.Result (ProducerMap,ProducerGraph(..))
import AbstractInterpretation.LiveVariable.Pretty
import AbstractInterpretation.LiveVariable.Result (LVAResult)
import AbstractInterpretation.HeapPointsTo.Result (HPTResult)


class SameAs a where
  sameAs :: a -> a -> IO ()

instance SameAs TypeEnv where
  sameAs found expected = found `shouldBe` expected

instance SameAs ProducerMap where
  sameAs found expected = (PP found) `shouldBe` (PP expected)

instance SameAs HPTResult where
  sameAs found expected = (PP found) `shouldBe` (PP expected)

instance SameAs LVAResult where
  sameAs found expected = (PP found) `shouldBe` (PP expected)

instance SameAs ProducerGraph where
  sameAs found expected = (PP found) `shouldBe` (PP expected)

instance (SameAs a, SameAs b) => SameAs (a, b) where
  sameAs (f1, f2) (e1, e2) = do
    f1 `sameAs` e1
    f2 `sameAs` e2

instance SameAs Exp where
  -- | Check if the two expression are the same, if not renders them
  -- in a pretty printed form.
  sameAs found expected = (PP found) `shouldBe` (PP expected)

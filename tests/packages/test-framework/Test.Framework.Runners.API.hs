{-# LINE 1 "./Test/Framework/Runners/API.hs" #-}
{-# LINE 1 "dist/dist-sandbox-235ea54e/build/autogen/cabal_macros.h" #-}
                                                                

                                   






                                    






                          






                                






                          






                                






                        






                                






                      






                        






                     






                       






                  






                    






                        






                         






                       






                   






                      






                          







{-# LINE 2 "./Test/Framework/Runners/API.hs" #-}
{-# LINE 1 "./Test/Framework/Runners/API.hs" #-}
-- | This module exports everything that you need to be able to create your own test runner.
module Test.Framework.Runners.API (
        module Test.Framework.Runners.Options,
        TestRunner(..), runTestTree
    ) where

import Test.Framework.Runners.Options
import Test.Framework.Runners.Core

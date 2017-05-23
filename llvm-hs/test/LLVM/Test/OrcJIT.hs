{-# LANGUAGE ForeignFunctionInterface, OverloadedStrings #-}
module LLVM.Test.OrcJIT where

import Test.Tasty
import Test.Tasty.HUnit

import LLVM.Test.Support

import Control.Applicative
import Data.ByteString (ByteString)
import Data.Foldable
import Data.IORef
import Data.Word
import Foreign.Ptr

import LLVM.Internal.PassManager
import qualified LLVM.Internal.FFI.PassManager as FFI
import LLVM.Context
import LLVM.Module
import qualified LLVM.Internal.FFI.Module as FFI
import LLVM.OrcJIT
import LLVM.OrcJIT.IRCompileLayer (IRCompileLayer, withIRCompileLayer)
import LLVM.Internal.OrcJIT.CompileLayer
import qualified LLVM.OrcJIT.IRCompileLayer as IRCompileLayer
import LLVM.OrcJIT.CompileOnDemandLayer (CompileOnDemandLayer, withIndirectStubsManagerBuilder, withJITCompileCallbackManager, withCompileOnDemandLayer)
import LLVM.OrcJIT.IRTransformLayer
import qualified LLVM.OrcJIT.CompileOnDemandLayer as CODLayer
import LLVM.Target

testModule :: ByteString
testModule =
  "; ModuleID = '<string>'\n\
  \source_filename = \"<string>\"\n\
  \\n\
  \declare i32 @testFunc()\n\
  \define i32 @main(i32, i8**) {\n\
  \  %3 = call i32 @testFunc()\n\
  \  ret i32 %3\n\
  \}\n"

withTestModule :: (Module -> IO a) -> IO a
withTestModule f = withContext $ \context -> withModuleFromLLVMAssembly' context testModule f

myTestFuncImpl :: IO Word32
myTestFuncImpl = return 42

foreign import ccall "wrapper"
  wrapTestFunc :: IO Word32 -> IO (FunPtr (IO Word32))

foreign import ccall "dynamic"
  mkMain :: FunPtr (IO Word32) -> IO Word32

nullResolver :: MangledSymbol -> IO JITSymbol
nullResolver s = putStrLn "nullresolver" >> return (JITSymbol 0 (JITSymbolFlags False False))

resolver :: CompileLayer l => MangledSymbol -> l -> MangledSymbol -> IO JITSymbol
resolver testFunc compileLayer symbol
  | symbol == testFunc = do
      funPtr <- wrapTestFunc myTestFuncImpl
      let addr = ptrToWordPtr (castFunPtrToPtr funPtr)
      return (JITSymbol addr (JITSymbolFlags False True))
  | otherwise = IRCompileLayer.findSymbol compileLayer symbol True

moduleTransform :: IORef Bool -> Ptr FFI.Module -> IO (Ptr FFI.Module)
moduleTransform passmanagerSuccessful modulePtr = do
  withPassManager defaultCuratedPassSetSpec { optLevel = Just 2 } $ \(PassManager pm) -> do
    success <- toEnum . fromIntegral <$> FFI.runPassManager pm modulePtr
    writeIORef passmanagerSuccessful success
    pure modulePtr

tests :: TestTree
tests =
  testGroup "OrcJit" [
    testCase "eager compilation" $ do
      withTestModule $ \mod ->
        withHostTargetMachine $ \tm ->
          withObjectLinkingLayer $ \objectLayer ->
            withIRCompileLayer objectLayer tm $ \compileLayer -> do
              testFunc <- IRCompileLayer.mangleSymbol compileLayer "testFunc"
              IRCompileLayer.withModuleSet
                compileLayer
                [mod]
                (SymbolResolver (resolver testFunc compileLayer) nullResolver) $
                \moduleSet -> do
                  mainSymbol <- IRCompileLayer.mangleSymbol compileLayer "main"
                  JITSymbol mainFn _ <- IRCompileLayer.findSymbol compileLayer mainSymbol True
                  result <- mkMain (castPtrToFunPtr (wordPtrToPtr mainFn))
                  result @?= 42,

    testCase "IRTransformLayer" $ do
      passmanagerSuccessful <- newIORef False
      withTestModule $ \mod ->
        withHostTargetMachine $ \tm ->
          withObjectLinkingLayer $ \objectLayer ->
            withIRCompileLayer objectLayer tm $ \compileLayer -> do
              withIRTransformLayer compileLayer tm (moduleTransform passmanagerSuccessful) $ \compileLayer -> do
                testFunc <- IRCompileLayer.mangleSymbol compileLayer "testFunc"
                IRCompileLayer.withModuleSet
                  compileLayer
                  [mod]
                  (SymbolResolver (resolver testFunc compileLayer) nullResolver) $
                  \moduleSet -> do
                    mainSymbol <- IRCompileLayer.mangleSymbol compileLayer "main"
                    JITSymbol mainFn _ <- IRCompileLayer.findSymbol compileLayer mainSymbol True
                    result <- mkMain (castPtrToFunPtr (wordPtrToPtr mainFn))
                    result @?= 42
                    assert (readIORef passmanagerSuccessful),

    testCase "lazy compilation" $ do
      withTestModule $ \mod ->
        withHostTargetMachine $ \tm -> do
          triple <- getTargetMachineTriple tm
          withObjectLinkingLayer $ \objectLayer ->
            withIRCompileLayer objectLayer tm $ \baseLayer ->
              withIndirectStubsManagerBuilder triple $ \stubsMgr ->
                withJITCompileCallbackManager triple Nothing $ \callbackMgr ->
                  withCompileOnDemandLayer baseLayer tm (\x -> return [x]) callbackMgr stubsMgr False $ \compileLayer -> do
                    testFunc <- CODLayer.mangleSymbol compileLayer "testFunc"
                    CODLayer.withModuleSet
                      compileLayer
                      [mod]
                      (SymbolResolver (resolver testFunc compileLayer) nullResolver) $
                      \moduleSet -> do
                        mainSymbol <- CODLayer.mangleSymbol compileLayer "main"
                        JITSymbol mainFn _ <- CODLayer.findSymbol compileLayer mainSymbol True
                        result <- mkMain (castPtrToFunPtr (wordPtrToPtr mainFn))
                        result @?= 42
  ]

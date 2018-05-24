{-# LANGUAGE LambdaCase, RecordWildCards, TemplateHaskell, PatternSynonyms #-}
module Pipeline where

import Control.Monad
import Data.List (intersperse)
import Data.Maybe (maybe, fromJust, fromMaybe)
import Text.Printf
import Text.Pretty.Simple (pPrint)
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>), (</>))
import qualified Text.Show.Pretty as PP

import Check hiding (check)
import Eval
import Grin
import TypeEnv
import TypeCheck
import Optimizations
import qualified Statistics
import Pretty()
import Transformations.AssignStoreIDs
import Transformations.GenerateEval
import qualified Transformations.Simplifying.Vectorisation2 as Vectorisation2
import Transformations.Simplifying.Vectorisation
import Transformations.BindNormalisation
import qualified Lint
import PrettyLint
import Transformations.Simplifying.SplitFetch
import Transformations.Simplifying.CaseSimplification
import Transformations.Simplifying.RightHoistFetch
import Transformations.Optimising.Inlining (inlineEval, inlineApply)
import qualified Transformations.Simplifying.RightHoistFetch2 as RHF
import Transformations.Simplifying.RegisterIntroduction
import Transformations.Playground
import AbstractInterpretation.AbstractRunGrin
import AbstractInterpretation.HPTResult
import qualified AbstractInterpretation.HPTResultNew as HPT
import AbstractInterpretation.PrettyHPT
import qualified AbstractInterpretation.Pretty as HPT
import qualified AbstractInterpretation.IR as HPT
import qualified AbstractInterpretation.CodeGen as HPT
import qualified AbstractInterpretation.Reduce as HPT
import qualified Reducer.LLVM.CodeGen as CGLLVM
import qualified Reducer.LLVM.JIT as JITLLVM
import System.Directory
import System.Process
import Data.Bifunctor

import qualified Data.Bimap as Bimap
import Data.Map as Map
import LLVM.Pretty (ppllvm)
import qualified Data.Text.Lazy.IO as Text

import Control.Monad.Trans.Reader
import Control.Monad.Trans.State.Strict
import Control.Monad.IO.Class
import Lens.Micro.TH
import Lens.Micro.Mtl
import Data.Set
import System.FilePath
import Control.DeepSeq
import Debug.Trace



type RenameVariablesMap = Map String String

data Transformation
  -- Simplifying
  = RegisterIntroduction
  | Vectorisation
  | SplitFetch
  | CaseSimplification
  | RightHoistFetch
  | InlineEval
  | InlineApply
  -- Misc
  | GenerateEval
  | BindNormalisation
  | ConstantFolding
  -- Optimizations
  | EvaluatedCaseElimination
  | TrivialCaseElimination
  | SparseCaseOptimisation
  | UpdateElimination
  | CopyPropagation
  | ConstantPropagation
  | DeadProcedureElimination
  | DeadVariableElimination
  | CommonSubExpressionElimination
  | CaseCopyPropagation
  | CaseHoisting
  | GeneralizedUnboxing
  | ArityRaising
  | LateInlining
  deriving (Enum, Eq, Ord, Show)

noTypeEnv :: (Exp -> Exp) -> (TypeEnv, Exp) -> (TypeEnv, Exp)
noTypeEnv f (t, e) = (t, f e)

transformation :: Int -> Transformation -> (TypeEnv, Exp) -> (TypeEnv, Exp)
transformation n = \case
  CaseSimplification              -> noTypeEnv caseSimplification
  SplitFetch                      -> noTypeEnv splitFetch
  Vectorisation                   -> Vectorisation2.vectorisation
  RegisterIntroduction            -> noTypeEnv $ registerIntroductionI n
  InlineEval                      -> inlineEval
  InlineApply                     -> inlineApply
  BindNormalisation               -> noTypeEnv bindNormalisation
  RightHoistFetch                 -> noTypeEnv RHF.rightHoistFetch
  GenerateEval                    -> noTypeEnv generateEval
  ConstantFolding                 -> noTypeEnv constantFolding
  EvaluatedCaseElimination        -> noTypeEnv evaluatedCaseElimination
  TrivialCaseElimination          -> noTypeEnv trivialCaseElimination
  SparseCaseOptimisation          -> sparseCaseOptimisation
  UpdateElimination               -> noTypeEnv updateElimination
  CopyPropagation                 -> noTypeEnv copyPropagation
  ConstantPropagation             -> noTypeEnv constantPropagation
  DeadProcedureElimination        -> noTypeEnv deadProcedureElimination
  DeadVariableElimination         -> noTypeEnv deadVariableElimination
  CommonSubExpressionElimination  -> commonSubExpressionElimination
  CaseCopyPropagation             -> caseCopyPropagation
  CaseHoisting                    -> caseHoisting
  GeneralizedUnboxing             -> generalizedUnboxing
  ArityRaising                    -> arityRaising
  LateInlining                    -> lateInlining

-- TODO
precondition :: Transformation -> [Check]
precondition _ = []

postcondition :: Transformation -> [Check]
postcondition _ = []

newtype Hidden a = H a

instance Show (Hidden a) where
  show _ = "(hidden)"

instance Eq (Hidden a) where
  _ == _ = True

data HPTStep
  = CompileHPT
  | PrintHPT
  | RunHPTPure
  | PrintHPTResult
  deriving Show

data Pipeline
  = HPT HPTStep
  | T Transformation
  | Pass [Pipeline]
  | PrintGrinH (Hidden (Doc -> Doc))
  | PureEval
  | JITLLVM
  | PrintAST
  | SaveLLVM FilePath
  | SaveGrin FilePath
  | DebugTransformationH (Hidden (Exp -> Exp))
  | Statistics
  | PrintTypeEnv
  | Lint
  deriving Show

pattern PrintGrin :: (Doc -> Doc) -> Pipeline
pattern PrintGrin c <- PrintGrinH (H c)
  where PrintGrin c =  PrintGrinH (H c)

pattern DebugTransformation :: (Exp -> Exp) -> Pipeline
pattern DebugTransformation t <- DebugTransformationH (H t)
  where DebugTransformation t =  DebugTransformationH (H t)

data PipelineOpts = PipelineOpts
  { _poOutputDir :: FilePath
  }

defaultOpts :: PipelineOpts
defaultOpts = PipelineOpts
  { _poOutputDir = "./"
  }

type PipelineM a = ReaderT PipelineOpts (StateT PState IO) a
data PState = PState
    { _psExp        :: Exp
    , _psTransStep  :: Int
    , _psHPTProgram :: Maybe HPT.HPTProgram
    , _psHPTResult  :: Maybe HPT.HPTResult
    , _psTypeEnv    :: Maybe TypeEnv
    }

makeLenses ''PState
makeLenses ''PipelineOpts

data PipelineEff
  = None
  | ExpChanged
  deriving (Eq, Show)

pipelineStep :: Pipeline -> PipelineM PipelineEff
pipelineStep p = do
  case p of
    T{}     -> pure ()
    Pass{}  -> pure () -- each pass step will be printed anyway
    _       -> liftIO $ putStrLn $ printf "Pipeline: %-35s" (show p)
  before <- use psExp
  case p of
    HPT hptStep -> case hptStep of
      CompileHPT      -> compileHPT
      PrintHPT        -> printHPT
      RunHPTPure      -> runHPTPure
      PrintHPTResult  -> printHPTResult
    T t             -> transformationM t
    Pass pass       -> mapM_ pipelineStep pass
    PrintGrin d     -> printGrinM d
    PureEval        -> pureEval
    JITLLVM         -> jitLLVM
    SaveLLVM path   -> saveLLVM path
    SaveGrin path   -> saveGrin path
    PrintAST        -> printAST
    PrintTypeEnv    -> printTypeEnv
    DebugTransformation t -> debugTransformation t
    Statistics      -> statistics
    Lint            -> lintGrin
  after <- use psExp
  let eff = if before == after then None else ExpChanged
  case p of
    T{} -> liftIO $ putStrLn $ printf "Pipeline: %-35s has effect: %s" (show p) (show eff)
    _   -> pure ()
  -- TODO: Test this only for development mode.
  return eff

compileHPT :: PipelineM ()
compileHPT = do
  grin <- use psExp
  let hptProgram = HPT.codeGen grin
  psHPTProgram .= Just hptProgram

printHPT :: PipelineM ()
printHPT = do
  hptProgram <- use psHPTProgram
  let printHPT a = do
        putStrLn . show . HPT.prettyInstructions (Just a) . HPT.hptInstructions $ a
        putStrLn $ printf "memory size    %d" $ HPT.hptMemoryCounter a
        putStrLn $ printf "register count %d" $ HPT.hptRegisterCounter a
        putStrLn $ printf "variable count %d" $ Map.size $ HPT.hptRegisterMap a
  maybe (pure ()) (liftIO . printHPT) hptProgram

printHPTResult :: PipelineM ()
printHPTResult = do
  Just result <- use psHPTResult
  liftIO $ putStrLn . show . pretty $ result

runHPTPure :: PipelineM ()
runHPTPure = do
  Just hptProgram <- use psHPTProgram
  let hptResult = HPT.evalHPT hptProgram
      result = HPT.toHPTResult hptProgram hptResult
  psHPTResult .= Just result
  psTypeEnv .= Just (typeEnvFromHPTResult result)

printTypeEnv :: PipelineM ()
printTypeEnv = do
  Just typeEnv <- use psTypeEnv
  liftIO $ putStrLn . show . pretty $ typeEnv

preconditionCheck :: Transformation -> PipelineM ()
preconditionCheck t = do
  exp <- use psExp
  forM_ (checks Nothing (precondition t) exp) $ \case
    (c, r) -> liftIO . putStrLn $ unwords ["The", show c, "precondition of", show t, ": ", show r]

postconditionCheck :: Transformation -> PipelineM ()
postconditionCheck t = do
  exp <- use psExp
  forM_ (checks Nothing (postcondition t) exp) $ \case
    (c, r) -> liftIO . putStrLn $ unwords ["The", show c, "postcondition of", show t, ": ", show r]

transformationM :: Transformation -> PipelineM ()
transformationM t = do
  preconditionCheck t
  env0 <- fromMaybe (traceShow "emptyTypEnv is used" emptyTypeEnv) <$> use psTypeEnv
  n    <- use psTransStep
  exp0 <- use psExp
  let (env1, exp1) = transformation n t (env0, exp0)
  psTypeEnv .= Just env1
  psExp     .= exp1
  psTransStep %= (+1)
  postconditionCheck t

pureEval :: PipelineM ()
pureEval = do
  e <- use psExp
  liftIO (print =<< pretty <$> evalProgram PureReducer e)

printGrinM :: (Doc -> Doc) -> PipelineM ()
printGrinM color = do
  e <- use psExp
  liftIO . putStrLn . show . color $ pretty e

jitLLVM :: PipelineM ()
jitLLVM = do
  e <- use psExp
  Just typeEnv <- use psTypeEnv
  liftIO $ do
    val <- JITLLVM.eagerJit (CGLLVM.codeGen typeEnv e) "grinMain"
    print $ pretty val

printAST :: PipelineM ()
printAST = do
  e <- use psExp
  pPrint e

saveGrin :: FilePath -> PipelineM ()
saveGrin fn = do
  n <- use psTransStep
  e <- use psExp
  outputDir <- view poOutputDir
  let fname = (concat [show n,".",fn])
  let content = show $ plain $ pretty e
  liftIO $ do
    createDirectoryIfMissing True outputDir
    writeFile (outputDir </> fname) content

saveLLVM :: FilePath -> PipelineM ()
saveLLVM fname' = do
  e <- use psExp
  n <- use psTransStep
  Just typeEnv <- use psTypeEnv
  o <- view poOutputDir
  let fname = o </> concat [show n,".", fname']
      code = CGLLVM.codeGen typeEnv e
      llName = printf "%s.ll" fname
      sName = printf "%s.s" fname
  liftIO . void $ do
    Text.putStrLn $ ppllvm code
    putStrLn "* to LLVM *"
    _ <- CGLLVM.toLLVM llName code
    putStrLn "* LLVM X64 codegen *"
    callCommand $ printf "opt-5.0 -O3 %s | llc-5.0 -o %s" llName sName
    readFile sName >>= putStrLn

debugTransformation :: (Exp -> Exp) -> PipelineM ()
debugTransformation t = do
  e <- use psExp
  liftIO . putStrLn . show $ pretty (t e)

statistics :: PipelineM ()
statistics = do
  e <- use psExp
  liftIO . print $ Statistics.statistics e

lintGrin :: PipelineM ()
lintGrin = do
  exp <- use psExp
  Just typeEnv <- use psTypeEnv
  let lintExp@(_, errorMap) = Lint.lint typeEnv exp
  when (Map.size errorMap > 0 || True) $ do
    liftIO . putStrLn . show $ prettyLintExp lintExp

check :: PipelineM ()
check = do
  e <- use psExp
  let nonUnique = nonUniqueNames e
  liftIO $ putStrLn $ unwords ["Non unique names:", show nonUnique]
  let nonDefined = nonDefinedNames e
  liftIO . putStrLn $ unwords ["Non defined names:", show nonDefined]


-- | Runs the pipeline and returns the last version of the given
-- expression.
pipeline :: PipelineOpts -> Exp -> [Pipeline] -> IO ([(Pipeline, PipelineEff)], Exp)
pipeline o e ps = do
  print ps
  fmap (second _psExp) .
    flip runStateT start .
    flip runReaderT o $
    mapM (\p -> (,) p <$> pipelineStep p) ps
  where
    start = PState
      { _psExp        = e
      , _psTransStep  = 0
      , _psHPTProgram = Nothing
      , _psHPTResult  = Nothing
      , _psTypeEnv    = Nothing
      }

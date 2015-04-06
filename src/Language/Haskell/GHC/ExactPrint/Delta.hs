{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecursiveDo #-}
module Language.Haskell.GHC.ExactPrint.Delta  (relativiseApiAnns) where

import Control.Monad.RWS
import Control.Monad.Trans.Free

import Data.Data (Data)
import Data.List (sort, nub, partition)

import Language.Haskell.GHC.ExactPrint.Types
import Language.Haskell.GHC.ExactPrint.Utils
import Language.Haskell.GHC.ExactPrint.Transform
import Language.Haskell.GHC.ExactPrint.Annotate (AnnotationF(..), Annotated
                                                , markLocated, Annotate(..))

import qualified GHC
import qualified SrcLoc         as GHC

import qualified Data.Map as Map


-- ---------------------------------------------------------------------
-- | Transform concrete annotations into relative annotations which are
-- more useful when transforming an AST.
relativiseApiAnns :: Annotate ast
                  => GHC.Located ast
                  -> GHC.ApiAnns
                  -> Anns
relativiseApiAnns modu' ghcAnns'
   = runDelta (markLocated modu) ghcAnns (ss2pos ss)
     where
      (ghcAnns,modu@(GHC.L ss _)) = fixBugsInAst ghcAnns' modu'

-- ---------------------------------------------------------------------
--
-- | Type used in the Delta Monad.
type Delta a = RWS DeltaReader DeltaWriter DeltaState a

runDelta :: Annotated () -> GHC.ApiAnns -> Pos -> Anns
runDelta action ga priorEnd =
  ($ mempty) . appEndo . finalAnns . snd
  . (\next -> execRWS next initialDeltaReader (defaultDeltaState priorEnd ga))
  . deltaInterpret $ action

-- ---------------------------------------------------------------------

data DeltaReader = DeltaReader
       { -- | Current `SrcSpan`
         curSrcSpan  :: !GHC.SrcSpan

         -- | Constuctor of current AST element, useful for
         -- debugging
       , annConName  :: !AnnConName

         -- | Start column of the current layout block
       , layoutStart :: !LayoutStartCol
       }

data DeltaWriter = DeltaWriter
       { -- | Final list of annotations
         finalAnns :: !(Endo (Map.Map AnnKey Annotation))

         -- | Used locally to pass Keywords, delta pairs relevant to a specific
         -- subtree to the parent.
       , annKds    :: ![(KeywordId, DeltaPos)]
       }

data DeltaState = DeltaState
       { -- | Position reached when processing the last element
         priorEndPosition    :: !Pos

         -- | Position reached when processing last AST element
         --   this is necessary to enforce layout rules.
       , priorEndASTPosition :: !Pos

         -- | Ordered list of comments still to be allocated
       , apComments :: ![Comment]

         -- | The original GHC Delta Annotations
       , apAnns :: !GHC.ApiAnns
       }

-- ---------------------------------------------------------------------

initialDeltaReader :: DeltaReader
initialDeltaReader =
  DeltaReader
    { curSrcSpan = GHC.noSrcSpan
    , annConName = annGetConstr ()
    , layoutStart = 0
    }

defaultDeltaState :: Pos -> GHC.ApiAnns -> DeltaState
defaultDeltaState priorEnd ga =
    DeltaState
      { priorEndPosition = priorEnd
      , priorEndASTPosition = priorEnd
      , apComments = cs
      , apAnns     = ga
      }
  where
    cs :: [Comment]
    cs = flattenedComments ga

    flattenedComments :: GHC.ApiAnns -> [Comment]
    flattenedComments (_,cm) =
      map tokComment . GHC.sortLocated . concat $ Map.elems cm

    tokComment :: GHC.Located GHC.AnnotationComment -> Comment
    tokComment t@(GHC.L lt _) = Comment (ss2span lt) (ghcCommentText t)

-- Writer helpers

tellFinalAnn :: (AnnKey, Annotation) -> Delta ()
tellFinalAnn (k, v) =
  tell (mempty { finalAnns = Endo (Map.insertWith (<>) k v) })

tellKd :: (KeywordId, DeltaPos) -> Delta ()
tellKd kd = tell (mempty { annKds = [kd] })


instance Monoid DeltaWriter where
  mempty = DeltaWriter mempty mempty
  (DeltaWriter a b) `mappend` (DeltaWriter c d) = DeltaWriter (a <> c) (b <> d)

-----------------------------------
-- Free Monad Interpretation code

deltaInterpret :: Annotated a -> Delta a
deltaInterpret = iterTM go
  where
    go :: AnnotationF (Delta a) -> Delta a
    go (MarkEOF next) = addEofAnnotation >> next
    go (MarkPrim kwid _ next) =
      addDeltaAnnotation kwid >> next
    go (MarkOutside akwid kwid next) =
      addDeltaAnnotationsOutside akwid kwid >> next
    go (MarkInside akwid next) =
      addDeltaAnnotationsInside akwid >> next
    go (MarkMany akwid next) = addDeltaAnnotations akwid >> next
    go (MarkOffsetPrim akwid n _ next) = addDeltaAnnotationLs akwid n >> next
    go (MarkAfter akwid next) = addDeltaAnnotationAfter akwid >> next
    go (WithAST lss layoutflag prog next) =
      withAST lss layoutflag (deltaInterpret prog) >> next
    go (CountAnns kwid next) = countAnnsDelta kwid >>= next
    go (SetLayoutFlag action next) = setLayoutFlag (deltaInterpret action)  >> next
    go (MarkExternal ss akwid _ next) = addDeltaAnnotationExt ss akwid >> next
    go (StoreOriginalSrcSpan ss next) = storeOriginalSrcSpanDelta ss >>= next
    go (GetSrcSpanForKw kw next) = getSrcSpanForKw kw >>= next

-- | Used specifically for "HsLet"
setLayoutFlag :: Delta () -> Delta ()
setLayoutFlag action = do
  c <- srcSpanStartColumn <$> getSrcSpan
  local (\s -> s { layoutStart = LayoutStartCol c }) action

-- ---------------------------------------------------------------------

storeOriginalSrcSpanDelta :: GHC.SrcSpan -> Delta GHC.SrcSpan
storeOriginalSrcSpanDelta ss = do
  tellKd (AnnList ss,DP (0,0))
  return ss

-- ---------------------------------------------------------------------

-- | This function exists to overcome a shortcoming in the GHC AST for 7.10.1
getSrcSpanForKw :: GHC.AnnKeywordId -> Delta GHC.SrcSpan
getSrcSpanForKw kw = do
-- ++AZ++ TODO: Now using AnnEofPos, no need to remove it and update state
    ga <- gets apAnns
    ss <- getSrcSpan
    case GHC.getAnnotation ga ss kw of
      []     -> return GHC.noSrcSpan
      (sp:_) -> return sp
    {-
    s <- get
    let ga = apAnns s
    ss <- getSrcSpan
    let (sss,ga') = GHC.getAndRemoveAnnotation ga ss kw
    put s { apAnns = ga' }
    case sss of
      []     -> return GHC.noSrcSpan
      (sp:_) -> return sp
    -}

-- ---------------------------------------------------------------------

getSrcSpan :: Delta GHC.SrcSpan
getSrcSpan = asks curSrcSpan

withSrcSpanDelta :: Data a => GHC.Located a -> Delta b -> Delta b
withSrcSpanDelta (GHC.L l a) =
  local (\s -> s { curSrcSpan = l
                 , annConName = annGetConstr a
                 })


getUnallocatedComments :: Delta [Comment]
getUnallocatedComments = gets apComments

putUnallocatedComments :: [Comment] -> Delta ()
putUnallocatedComments cs = modify (\s -> s { apComments = cs } )

-- ---------------------------------------------------------------------

adjustDeltaForOffsetM :: DeltaPos -> Delta DeltaPos
adjustDeltaForOffsetM dp = do
  colOffset <- asks layoutStart
  return (adjustDeltaForOffset colOffset dp)

adjustDeltaForOffset :: LayoutStartCol -> DeltaPos -> DeltaPos
adjustDeltaForOffset _colOffset              dp@(DP (0,_)) = dp -- same line
adjustDeltaForOffset (LayoutStartCol colOffset) (DP (l,c)) = DP (l,c - colOffset)

-- ---------------------------------------------------------------------

getPriorEnd :: Delta Pos
getPriorEnd = gets priorEndPosition

getPriorEndAST :: Delta Pos
getPriorEndAST = gets priorEndASTPosition

setPriorEnd :: Pos -> Delta ()
setPriorEnd pe =
  modify (\s -> s { priorEndPosition = pe })

setPriorEndAST :: Pos -> Delta ()
setPriorEndAST pe =
  modify (\s -> s { priorEndPosition = pe
                  , priorEndASTPosition = pe })


setLayoutOffset :: LayoutStartCol -> Delta a -> Delta a
setLayoutOffset lhs = local (\s -> s { layoutStart = lhs })

-- -------------------------------------

getAnnotationDelta :: GHC.AnnKeywordId -> Delta [GHC.SrcSpan]
getAnnotationDelta an = do
    ga <- gets apAnns
    ss <- getSrcSpan
    return $ GHC.getAnnotation ga ss an

getAndRemoveAnnotationDelta :: GHC.SrcSpan -> GHC.AnnKeywordId -> Delta [GHC.SrcSpan]
getAndRemoveAnnotationDelta sp an = do
    ga <- gets apAnns
    let (r,ga') = GHC.getAndRemoveAnnotation ga sp an
    r <$ modify (\s -> s { apAnns = ga' })

-- ---------------------------------------------------------------------

-- |Add some annotation to the currently active SrcSpan
addAnnotationsDelta :: Annotation -> Delta ()
addAnnotationsDelta ann = do
    l <- ask
    tellFinalAnn (getAnnKey l ,ann)

getAnnKey :: DeltaReader -> AnnKey
getAnnKey DeltaReader {curSrcSpan, annConName} = AnnKey curSrcSpan annConName

-- -------------------------------------

addAnnDeltaPos :: KeywordId -> DeltaPos -> Delta ()
addAnnDeltaPos kw dp = tellKd (kw, dp)

-- -------------------------------------

-- | Enter a new AST element. Maintain SrcSpan stack
withAST :: Data a => GHC.Located a -> LayoutFlag -> Delta b -> Delta b
withAST lss@(GHC.L ss _) layout action = do
  return () `debug` ("enterAST:(annkey,layout)=" ++ show (mkAnnKey lss,layout))
  -- Calculate offset required to get to the start of the SrcSPan
  off <- asks layoutStart
  let newOff =
        case layout of
          LayoutRules   -> (LayoutStartCol (srcSpanStartColumn ss))
          NoLayoutRules -> off

  (setLayoutOffset newOff .  withSrcSpanDelta lss) (do

    let maskWriter s = s { annKds = [] }

    -- make sure all kds are relative to the start of the SrcSpan
    let spanStart = ss2pos ss

    cs <- do
      priorEndBeforeComments <- getPriorEnd
      if GHC.isGoodSrcSpan ss && priorEndBeforeComments < ss2pos ss
        then
          commentAllocation (priorComment spanStart) return
        else
          return []
    priorEndAfterComments <- getPriorEnd
    let edp = adjustDeltaForOffset
                -- Use the propagated offset if one is set
                -- Note that we need to use the new offset if it has
                -- changed.
                newOff (ss2delta priorEndAfterComments ss)
    peAST <- getPriorEndAST
    let edpAST = adjustDeltaForOffset
                  newOff (ss2delta peAST ss)
    -- Preparation complete, perform the action
    when (GHC.isGoodSrcSpan ss && priorEndAfterComments < ss2pos ss)
            (setPriorEndAST (ss2pos ss))
    (res, w) <- censor maskWriter (listen action)

    let kds = annKds w
        an = Ann
               { annEntryDelta = edp
               , annDelta   = ColDelta (srcSpanStartColumn ss
                                         - getLayoutStartCol off)
               , annTrueEntryDelta  = edpAST
               , annPriorComments = cs
               , annsDP     = kds }

    addAnnotationsDelta an
     `debug` ("leaveAST:(annkey,an)=" ++ show (mkAnnKey lss,an))
    return res)


-- ---------------------------------------------------------------------
-- |Split the ordered list of comments into ones that occur prior to
-- the give SrcSpan and the rest
priorComment :: Pos -> Comment -> Bool
priorComment start (Comment s _) = fst s < start

allocateComments :: (Comment -> Bool) -> [Comment] -> ([Comment], [Comment])
allocateComments = partition

-- ---------------------------------------------------------------------

addAnnotationWorker :: KeywordId -> GHC.SrcSpan -> Delta ()
addAnnotationWorker ann pa =
  unless (isPointSrcSpan pa) $
    do
      pe <- getPriorEnd
      ss <- getSrcSpan
      let p = ss2delta pe pa
      case (ann,isGoodDelta p) of
        (G GHC.AnnComma,False) -> return ()
        (G GHC.AnnSemi, False) -> return ()
        (G GHC.AnnOpen, False) -> return ()
        (G GHC.AnnClose,False) -> return ()
        _ -> do
          p' <- adjustDeltaForOffsetM p
          commentAllocation (priorComment (ss2pos pa)) (mapM_ addDeltaComment)
          addAnnDeltaPos ann p'
          setPriorEndAST (ss2posEnd pa)
              `debug` ("addAnnotationWorker:(ss,ss,pe,pa,p,p',ann)=" ++ show (showGhc ss,ss2span ss,pe,ss2span pa,p,p',ann))

-- ---------------------------------------------------------------------

commentAllocation :: (Comment -> Bool)
                  -> ([DComment] -> Delta a)
                  -> Delta a
commentAllocation p k = do
  cs <- getUnallocatedComments
  let (allocated,cs') = allocateComments p cs
  putUnallocatedComments cs'
  k =<< mapM makeDeltaComment allocated


makeDeltaComment :: Comment -> Delta DComment
makeDeltaComment (Comment paspan str) = do
  let pa = span2ss paspan
  pe <- getPriorEnd
  let p = ss2delta pe pa
  p' <- adjustDeltaForOffsetM p
  setPriorEnd (ss2posEnd pa)
  let e = pos2delta pe (snd paspan)
  e' <- adjustDeltaForOffsetM e
  return $ DComment (p', e') str

addDeltaComment :: DComment -> Delta ()
addDeltaComment d@(DComment (p, _) _) = do
  addAnnDeltaPos (AnnComment d) p

-- ---------------------------------------------------------------------

-- | Look up and add a Delta annotation at the current position, and
-- advance the position to the end of the annotation
addDeltaAnnotation :: GHC.AnnKeywordId -> Delta ()
addDeltaAnnotation ann = do
  ss <- getSrcSpan
  when (ann == GHC.AnnVal) (debugM (showGhc ss))
  ma <- getAnnotationDelta ann
  when (ann == GHC.AnnVal && null ma) (debugM "empty")
  case nub ma of -- ++AZ++ TODO: get rid of duplicates earlier
    [] -> return () `debug` ("addDeltaAnnotation empty ma for:" ++ show ann)
    [pa] -> addAnnotationWorker (G ann) pa
    _ -> error $ "addDeltaAnnotation:(ss,ann,ma)=" ++ showGhc (ss,ann,ma)

-- | Look up and add a Delta annotation appearing beyond the current
-- SrcSpan at the current position, and advance the position to the
-- end of the annotation
addDeltaAnnotationAfter :: GHC.AnnKeywordId -> Delta ()
addDeltaAnnotationAfter ann = do
  ss <- getSrcSpan
  ma <- getAnnotationDelta ann
  let ma' = filter (\s -> not (GHC.isSubspanOf s ss)) ma
  case ma' of
    [] -> return () `debug` "addDeltaAnnotation empty ma"
    [pa] -> addAnnotationWorker (G ann) pa
    _ -> error $ "addDeltaAnnotation:(ss,ann,ma)=" ++ showGhc (ss,ann,ma)

-- | Look up and add a Delta annotation at the current position, and
-- advance the position to the end of the annotation
addDeltaAnnotationLs :: GHC.AnnKeywordId -> Int -> Delta ()
addDeltaAnnotationLs ann off = do
  ma <- getAnnotationDelta ann
  case drop off ma of
    [] -> return ()
        -- `debug` ("addDeltaAnnotationLs:missed:(off,pe,ann,ma)=" ++ show (off,ss2span pe,ann,fmap ss2span ma))
    (pa:_) -> addAnnotationWorker (G ann) pa

-- | Look up and add possibly multiple Delta annotation at the current
-- position, and advance the position to the end of the annotations
addDeltaAnnotations :: GHC.AnnKeywordId -> Delta ()
addDeltaAnnotations ann = do
  ma <- getAnnotationDelta ann
  let do_one ap' = addAnnotationWorker (G ann) ap'
                    -- `debug` ("addDeltaAnnotations:do_one:(ap',ann)=" ++ showGhc (ap',ann))
  mapM_ do_one (sort ma)

-- | Look up and add possibly multiple Delta annotations enclosed by
-- the current SrcSpan at the current position, and advance the
-- position to the end of the annotations
addDeltaAnnotationsInside :: GHC.AnnKeywordId -> Delta ()
addDeltaAnnotationsInside ann = do
  ss <- getSrcSpan
  ma <- getAnnotationDelta ann
  let do_one ap' = addAnnotationWorker (G ann) ap'
                    -- `debug` ("addDeltaAnnotations:do_one:(ap',ann)=" ++ showGhc (ap',ann))
  let filtered = sort $ filter (\s -> GHC.isSubspanOf s ss) ma
  mapM_ do_one filtered

-- | Look up and add possibly multiple Delta annotations not enclosed by
-- the current SrcSpan at the current position, and advance the
-- position to the end of the annotations
addDeltaAnnotationsOutside :: GHC.AnnKeywordId -> KeywordId -> Delta ()
addDeltaAnnotationsOutside gann ann = do
  ss <- getSrcSpan
  unless (ss2span ss == ((1,1),(1,1))) $
    do
      ma <- getAndRemoveAnnotationDelta ss gann
      let do_one ap' = addAnnotationWorker ann ap'
      mapM_ do_one (sort $ filter (\s -> not (GHC.isSubspanOf s ss)) ma)

-- | Add a Delta annotation at the current position, and advance the
-- position to the end of the annotation
addDeltaAnnotationExt :: GHC.SrcSpan -> GHC.AnnKeywordId -> Delta ()
addDeltaAnnotationExt s ann = addAnnotationWorker (G ann) s

addEofAnnotation :: Delta ()
addEofAnnotation = do
  pe <- getPriorEnd
  ma <- withSrcSpanDelta (GHC.noLoc ()) (getAnnotationDelta GHC.AnnEofPos)
  case ma of
    [] -> return ()
    (pa:pss) -> do
      commentAllocation (const True) (mapM_ addDeltaComment)
      let DP (r,c) = ss2delta pe pa
      addAnnDeltaPos (G GHC.AnnEofPos) (DP (r, c - 1))
      setPriorEndAST (ss2posEnd pa) `warn` ("Trailing annotations after Eof: " ++ showGhc pss)


countAnnsDelta :: GHC.AnnKeywordId -> Delta Int
countAnnsDelta ann = do
  ma <- getAnnotationDelta ann
  return (length ma)

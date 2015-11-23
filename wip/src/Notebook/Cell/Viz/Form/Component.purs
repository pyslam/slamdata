module Notebook.Cell.Viz.Form.Component
  ( formComponent
  , initialState
  , Query(..)
  , QueryP()
  , StateP()
  , State()
  , ChildState()
  , ChildSlot()
  , ChildQuery()
  , DimensionQuery()
  , SeriesQuery()
  , MeasureQuery()
  , DimensionSlot()
  , SeriesSlot()
  , MeasureSlot()
  , DimensionState()
  , SeriesState()
  , MeasureState()
  ) where

import Prelude

import Control.Bind (join)
import Control.Monad (when)
import Control.Alt ((<|>))
import Data.Argonaut (JCursor())
import Data.Array (cons, (!!), null, singleton, range, take, snoc, length, zip)
import Data.Either (Either())
import Data.Foldable (for_, traverse_, foldl)
import Data.Traversable (for, traverse)
import Data.Tuple.Nested (uncurry3)
import Data.Tuple (Tuple(..))
import Data.Functor (($>))
import Data.Functor.Coproduct (Coproduct(), right, left)
import Data.Identity (Identity(..))
import Data.Lens (preview)
import Data.Lens.Index (ix)
import Data.Lens.Prism.Coproduct (_Left, _Right)
import Data.Maybe (Maybe(..), maybe, fromMaybe, isJust)
import Data.Maybe.Unsafe (fromJust)
import Form.Select.Component as S
import Form.SelectPair.Component as P
import Halogen
import Halogen.Component.ChildPath (ChildPath(), cpL, cpR, (:>), prjQuery, prjSlot)
import Halogen.Component.Utils (applyCF)
import Halogen.HTML.Events.Indexed as E
import Halogen.HTML.Indexed as H
import Halogen.HTML.Properties.Indexed as P
import Halogen.Themes.Bootstrap3 as B
import Model.Aggregation (Aggregation(..), allAggregations)
import Model.ChartConfiguration
import Model.Select (OptionVal, Select(..), autoSelect, except, filterSelect')
import Notebook.Cell.Viz.Form.Component.Render (gridClasses, GridClasses())
import Notebook.Common (Slam())
import Notebook.Effects (NotebookRawEffects())
import Render.Common (row)
import Render.CssClasses as Rc
import Utils.Array (enumerate)

data Query a
  = SetConfiguration ChartConfiguration a
  | GetConfiguration (ChartConfiguration -> a)

-- | In fact `State` could be something like this
-- | ```purescript
-- | type State = {dimensions :: Int, measures :: Int, series :: Int}
-- | ```
-- | TODO: try this approach
type State = ChartConfiguration

import Model.Select (emptySelect)

initialState :: State
initialState =
  ChartConfiguration { dimensions: []
                     , series: []
                     , measures: []
                     , aggregations: []
                     }

type DimensionSlot = Int
type SeriesSlot = Int
type MeasureSlot = Int
type ChildSlot = Either DimensionSlot (Either SeriesSlot MeasureSlot)

type DimensionQuery = S.Query JCursor
type SeriesQuery = S.Query JCursor
type MeasureQuery = P.QueryP Aggregation JCursor
type MeasureAggQuery = S.Query Aggregation
type MeasureSelQuery = S.Query JCursor
type ChildQuery = Coproduct DimensionQuery (Coproduct SeriesQuery MeasureQuery)

type DimensionState = Select JCursor
type SeriesState = Select JCursor
type MeasureState = P.StateP Aggregation JCursor NotebookRawEffects
type ChildState = Either DimensionState (Either SeriesState MeasureState)

type FormHTML = ParentHTML ChildState Query ChildQuery Slam ChildSlot
type FormDSL = ParentDSL State ChildState Query ChildQuery Slam ChildSlot
type StateP = InstalledState State ChildState Query ChildQuery Slam ChildSlot
type QueryP = Coproduct Query (ChildF ChildSlot ChildQuery)

cpDimension :: ChildPath
               DimensionState ChildState
               DimensionQuery ChildQuery
               DimensionSlot ChildSlot
cpDimension = cpL

cpSeries :: ChildPath
            SeriesState ChildState
            SeriesQuery ChildQuery
            SeriesSlot ChildSlot
cpSeries = cpR :> cpL

cpMeasure :: ChildPath
             MeasureState ChildState
             MeasureQuery ChildQuery
             MeasureSlot ChildSlot
cpMeasure = cpR :> cpR


formComponent :: Component StateP QueryP Slam
formComponent = parentComponent' render eval peek

render
  :: ChartConfiguration -> ParentHTML ChildState Query ChildQuery Slam ChildSlot
render (ChartConfiguration conf) =
  H.div [ P.classes [ Rc.chartEditor ] ]
  $ if null conf.dimensions
    then renderRowsWithoutDimension 1 2 (renderCategoryRow)
    else renderRows 0 [ ]
  where
  renderCategoryRow :: Array FormHTML
  renderCategoryRow =
       singleton
    $  row
    $  maybe [] (renderCategory clss.first 0) (conf.series !! 0)
    <> maybe [] (renderMeasure clss.second 0) (conf.measures !! 0)
    <> maybe [] (renderSeries clss.third 0) (conf.series !! 1)
    where
    clss :: GridClasses
    clss = gridClasses (conf.series !! 0) (conf.measures !! 0) (conf.series !! 1)

  renderRowsWithoutDimension
    :: Int -> Int -> Array FormHTML -> Array FormHTML
  renderRowsWithoutDimension measureIx seriesIx acc =
    maybe acc
    (renderRowsWithoutDimension (measureIx + one) (seriesIx + one)
     <<< flip cons acc)
    $ renderOneRowWithoutDimension
        measureIx (conf.measures !! measureIx)
        seriesIx (conf.series !! seriesIx)

  renderOneRowWithoutDimension
    :: Int -> Maybe JSelect -> Int -> Maybe JSelect -> Maybe FormHTML
  renderOneRowWithoutDimension _ Nothing _ Nothing = Nothing
  renderOneRowWithoutDimension measureIx mbMeasure seriesIx mbSeries =
       pure
    $  row
    $  maybe [] (renderMeasure [ B.colXs4, B.colXsOffset4 ] measureIx) mbMeasure
    <> maybe [] (renderSeries [ B.colXs4 ] seriesIx) mbSeries

  renderRows
    :: Int -> Array FormHTML -> Array FormHTML
  renderRows ix acc =
    maybe acc (renderRows (ix + one) <<< flip cons acc)
    $ renderOneRow ix
    (conf.dimensions !! ix) (conf.series !! ix) (conf.measures !! ix)

  renderOneRow
    :: Int -> Maybe JSelect -> Maybe JSelect -> Maybe JSelect -> Maybe FormHTML
  renderOneRow _ Nothing Nothing Nothing = Nothing
  renderOneRow ix mbDimension mbSeries mbMeasure =
       pure
    $  row
    $  maybe [] (renderDimension clss.first ix) mbDimension
    <> maybe [] (renderMeasure clss.second ix) mbMeasure
    <> maybe [] (renderSeries clss.third ix) mbSeries
    where
    clss :: GridClasses
    clss = gridClasses mbDimension mbMeasure mbSeries

  renderDimension :: Array H.ClassName -> Int -> JSelect -> Array FormHTML
  renderDimension clss ix sel =
    [ H.form [ P.classes $ clss <> [ Rc.chartConfigureForm, Rc.chartDimension ] ]
      [ dimensionLabel
      , H.slot' cpDimension ix \_ -> { component: S.primarySelect
                                     , initialState: sel
                                     }
      ]
    ]

  renderMeasure :: Array H.ClassName -> Int -> JSelect -> Array FormHTML
  renderMeasure clss ix sel =
    [ H.form [ P.classes $ clss <> [ Rc.chartConfigureForm
                                   , Rc.chartMeasureOne
                                   , Rc.withAggregation
                                   ]
             ]
      [ measureLabel
      , H.slot' cpMeasure ix \_ -> { component: childMeasure ix sel
                                   , initialState: installedState
                                     $ P.initialState aggregationSelect
                                   }
      ]
    ]

  renderSeries :: Array H.ClassName -> Int -> JSelect -> Array FormHTML
  renderSeries clss ix sel =
    [ H.form [ P.classes $ clss <> [ Rc.chartConfigureForm
                                   , Rc.chartSeriesOne
                                   ]
             ]
      [ seriesLabel
      , H.slot' cpSeries ix \_ -> { component: childSelect ix
                                  , initialState: sel
                                  }
      ]
    ]

  renderCategory :: Array H.ClassName -> Int -> JSelect -> Array FormHTML
  renderCategory clss ix sel =
    [ H.form [ P.classes $ clss <> [ Rc.chartConfigureForm
                                   , Rc.chartCategory
                                   ]
             ]
      [ categoryLabel
      , H.slot' cpSeries ix \_ -> { component: S.primarySelect
                                  , initialState: sel
                                  }
      ]
    ]

  childMeasure i sel =
    P.selectPair
    $ if i == 0
      then { disableWhen: (< 2)
           , defaultWhen: (> 1)
           , mainState: sel
           , classes: []
           }
      else { disableWhen: (< 1)
           , defaultWhen: (const true)
           , mainState: sel
           , classes: []
           }


  aggregationSelect :: Select Aggregation
  aggregationSelect = Select { options: allAggregations
                             , value: Just Sum
                             }

  childSelect
    :: forall a. (OptionVal a) => Int -> Component (Select a) (S.Query a) Slam
  childSelect i =
    if i == 0
    then S.primarySelect
    else S.secondarySelect

  label :: String -> FormHTML
  label str = H.label [ P.classes [ B.controlLabel ] ] [ H.text str ]

  categoryLabel :: FormHTML
  categoryLabel = label "Category"

  dimensionLabel :: FormHTML
  dimensionLabel = label "Dimension"

  measureLabel :: FormHTML
  measureLabel = label "Measure"

  seriesLabel :: FormHTML
  seriesLabel = label "Series"

eval :: EvalParent Query State ChildState Query ChildQuery Slam ChildSlot
eval (SetConfiguration c@(ChartConfiguration conf) next) = do
  (ChartConfiguration r) <- get
  synchronizeDimensions r.dimensions conf.dimensions
  synchronizeSeries r.series conf.series
  synchronizeMeasures r.measures conf.measures
  synchronizeAggregations r.aggregations conf.aggregations
  modify (const c)
  pure next
  where
  synchronizeDimensions :: Array JSelect -> Array JSelect -> FormDSL Unit
  synchronizeDimensions = synchronize cpDimension

  synchronizeSeries :: Array JSelect -> Array JSelect -> FormDSL Unit
  synchronizeSeries = synchronize cpSeries

  synchronize :: _ -> Array JSelect -> Array JSelect -> FormDSL Unit
  synchronize prism old new =
    traverse_ (syncByIndex prism old new) $ range 0 $ getLastIndex old new

  syncByIndex :: _ -> Array JSelect -> Array JSelect -> Int -> FormDSL Unit
  syncByIndex prism old new i =
    if isJust $ old !! i
    then maybe (pure unit) (void <<< query' prism i <<< action <<< S.SetSelect)
         $ new !! i
    else pure unit

  synchronizeMeasures :: Array JSelect -> Array JSelect -> FormDSL Unit
  synchronizeMeasures old new =
    traverse_ (syncMeasureByIndex old new) $ range 0 $ getLastIndex old new

  syncMeasureByIndex :: Array JSelect -> Array JSelect -> Int -> FormDSL Unit
  syncMeasureByIndex old new i =
    if isJust $ old !! i
    then maybe (pure unit)
         (void <<< query' cpMeasure i <<< right
          <<< ChildF unit <<< action <<< S.SetSelect)
         $ new !! i
    else pure unit

  synchronizeAggregations
    :: Array (Select Aggregation) -> Array (Select Aggregation) -> FormDSL Unit
  synchronizeAggregations old new =
    traverse_ (syncAggByIndex old new) $ range 0 $ getLastIndex old new

  syncAggByIndex
    :: Array (Select Aggregation) -> Array (Select Aggregation) -> Int
    -> FormDSL Unit
  syncAggByIndex old new i =
    if isJust $ old !! i
    then maybe (pure unit)
         (void <<< query' cpMeasure i <<< left <<< action <<< S.SetSelect)
         $ new !! i
    else pure unit

  getLastIndex :: forall a b. Array a -> Array b -> Int
  getLastIndex old new =
    let oldL = length old
        newL = length new
    in (if oldL > newL then oldL else newL) - one


eval (GetConfiguration continue) = do
  (ChartConfiguration conf) <- get
  traceAnyA "FOO"
  get >>= traceAnyA
  forceRerender'
  dims <- getDimensions
  series <- getSeries
  measures <- getMeasures
  traceAnyA "get configuration"
  traceAnyA dims
  traceAnyA series
  traceAnyA measures
  traceAnyA "got configuration"
  r <- { dimensions: _, series: _, measures: _, aggregations: _}
       <$> getDimensions
       <*> getSeries
       <*> getMeasures
       <*> getAggregations
  pure $ continue $ ChartConfiguration r
  where
  getDimensions :: FormDSL (Array JSelect)
  getDimensions = do
    (ChartConfiguration conf) <- get
    traverse getDimension (range' 0 $ length conf.dimensions - 1)

  getDimension :: Int -> FormDSL JSelect
  getDimension i =
    map fromJust $ query' cpDimension i $ request S.GetSelect

  getSeries :: FormDSL (Array JSelect)
  getSeries = do
    (ChartConfiguration conf) <- get
    traverse getSerie (range' 0 $ length conf.series - 1)

  getSerie :: Int -> FormDSL JSelect
  getSerie i =
    map fromJust $ query' cpSeries i $ request S.GetSelect

  getMeasures :: FormDSL (Array JSelect)
  getMeasures = do
    (ChartConfiguration conf) <- get
    traverse getMeasure (range' 0 $ length conf.measures - 1)

  getMeasure :: Int -> FormDSL JSelect
  getMeasure i =
    map fromJust $ query' cpMeasure i $ right $ ChildF unit $ request S.GetSelect

  getAggregations :: FormDSL (Array (Select Aggregation))
  getAggregations = do
    (ChartConfiguration conf) <- get
    traverse getAggregation (range' 0 $ length conf.measures - 1)

  getAggregation :: Int -> FormDSL (Select Aggregation)
  getAggregation i =
    map fromJust $ query' cpMeasure i $ left $ request S.GetSelect

  range' :: Int -> Int -> Array Int
  range' start end =
    if end > start
    then range start end
    else []

import Debug.Trace
import Notebook.Common (forceRerender')

peek :: forall a. ChildF ChildSlot ChildQuery a -> FormDSL Unit
peek (ChildF slot query) =
  fromMaybe (pure unit)
  $   (dimensionPeek <$> prjSlot cpDimension slot <*> prjQuery cpDimension query)
  <|> (seriesPeek <$> prjSlot cpSeries slot <*> prjQuery cpSeries query)
  <|> (measurePeek <$> prjSlot cpMeasure slot <*> prjQuery cpMeasure query)

-- 1. All `fromJust` are safe here, because it's used only with index
--    of child that sent message.
-- 2. Filtering is incorrect. In fact we must take current state of
--    children and update it. (This component state have no meaning except
--    setting initial state of subcomponents)
dimensionPeek :: forall a. DimensionSlot -> DimensionQuery a -> FormDSL Unit
dimensionPeek i (S.Choose _ _) = do
  (ChartConfiguration conf) <- get
  dims <- getDimensionVals
  measures <- getMeasureVals
  traverse_ (traverseFn dims measures) $ enumerate conf.measures
  where
  traverseFn
    :: Array (Maybe JCursor) -> Array (Maybe JCursor)
    -> Tuple Int JSelect -> FormDSL Unit
  traverseFn dims measures (Tuple i sel) =
    let filtered = foldl filterSelect' sel $ take i measures <> dims
    in when (filtered /= sel) $ void
       $ query' cpMeasure i $ right $ ChildF unit $ action $ S.SetSelect filtered
dimensionPeek _ _ = pure unit

seriesPeek :: forall a. SeriesSlot -> SeriesQuery a -> FormDSL Unit
seriesPeek i (S.Choose _ _) = do
  (ChartConfiguration conf) <- get
  vals <- getSerieVals
  traverse_ (traverseFn vals) $ enumerate conf.series
  where
  traverseFn :: Array (Maybe JCursor) -> Tuple Int JSelect -> FormDSL Unit
  traverseFn vals (Tuple i sel) =
    let filtered = foldl filterSelect' sel $ take i vals
    in when (filtered /= sel) $ void
       $ query' cpSeries i $ action $ S.SetSelect filtered
seriesPeek _ _ = pure unit

measurePeek :: forall a. MeasureSlot -> MeasureQuery a -> FormDSL Unit
measurePeek s q =
  fromMaybe (pure unit)
  $   (measureAggregationPeek s <$> preview _Left q)
  -- we need index of that measure select to filter
  <|> (applyCF (measureSelectPeek s) <$> preview _Right q)

measureAggregationPeek :: forall a. MeasureSlot -> MeasureAggQuery a -> FormDSL Unit
measureAggregationPeek _ _ = pure unit

measureSelectPeek
  :: forall a. MeasureSlot -> Unit -> MeasureSelQuery a -> FormDSL Unit
measureSelectPeek i _ (S.Choose _ _) = do
  (ChartConfiguration conf) <- get
  vals <- getMeasureVals
  traverse_ (traverseFn vals) $ enumerate conf.measures
  where
  traverseFn :: Array (Maybe JCursor) -> Tuple Int JSelect -> FormDSL Unit
  traverseFn vals (Tuple i sel) =
    let filtered = foldl filterSelect' sel $ take i vals
    in when (filtered /= sel) $ void
       $ query' cpMeasure i $ right $ ChildF unit $ action $ S.SetSelect sel
measureSelectPeek _ _ _ = pure unit


getMeasureVals :: FormDSL (Array (Maybe JCursor))
getMeasureVals = do
  (ChartConfiguration conf) <- get
  for (range 0 $ length conf.measures - 1) \measureIx ->
    map join $ query' cpMeasure measureIx
    $ right $ ChildF unit $ request S.GetValue

getSerieVals :: FormDSL (Array (Maybe JCursor))
getSerieVals = do
  (ChartConfiguration conf) <- get
  for (range 0 $ length conf.series - 1) \seriesIx ->
    map join $ query' cpSeries seriesIx $ request S.GetValue

getDimensionVals :: FormDSL (Array (Maybe JCursor))
getDimensionVals = do
  (ChartConfiguration conf) <- get
  for (range 0 $ length conf.dimensions - 1) \dimensionIx ->
    map join $ query' cpDimension dimensionIx $ request S.GetValue

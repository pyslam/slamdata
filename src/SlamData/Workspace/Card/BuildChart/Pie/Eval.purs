module SlamData.Workspace.Card.BuildChart.Pie.Eval
  ( eval
  , module SlamData.Workspace.Card.BuildChart.Pie.Model
  ) where

import SlamData.Prelude

import Data.Argonaut (JArray, JCursor, Json, cursorGet, toNumber, toString)
import Data.Array as A
import Data.Foldable as F
import Data.Lens ((^?))
import Data.Lens as Lens
import Data.Map as M
import Data.Int as Int
import Data.Set as Set

import ECharts.Monad (DSL)
import ECharts.Commands as E
import ECharts.Types as ET
import ECharts.Types.Phantom (OptionI)
import ECharts.Types.Phantom as ETP

import Quasar.Types (FilePath)

import SlamData.Quasar.Class (class QuasarDSL)
import SlamData.Quasar.Error as QE
import SlamData.Quasar.Query as QQ
import SlamData.Workspace.Card.BuildChart.Pie.Model (Model, PieR)
import SlamData.Workspace.Card.CardType.ChartType (ChartType(Pie))
import SlamData.Workspace.Card.Chart.Aggregation as Ag
import SlamData.Workspace.Card.Chart.Axis (Axis, Axes, analyzeJArray)
import SlamData.Workspace.Card.Chart.Axis as Ax
import SlamData.Workspace.Card.Chart.BuildOptions.ColorScheme (colors)
import SlamData.Workspace.Card.Chart.Semantics as Sem
import SlamData.Workspace.Card.Eval.CardEvalT as CET
import SlamData.Workspace.Card.Port as Port


eval
  ∷ ∀ m
  . (Monad m, QuasarDSL m)
  ⇒ Model
  → FilePath
  → CET.CardEvalT m Port.Port
eval Nothing _ =
  QE.throw "Please select axis to aggregate"
eval (Just conf) resource = do
  numRecords ←
    CET.liftQ $ QQ.count resource

  when (numRecords > 10000)
    $ QE.throw
    $ "The 10000 record limit for visualizations has been exceeded - the current dataset contains "
    ⊕ show numRecords
    ⊕ " records. "
    ⊕ "Please consider using a 'limit' or 'group by' clause in the query to reduce the result size."

  records ←
    CET.liftQ $ QQ.all resource

  pure $ Port.ChartInstructions (buildPie conf records) Pie


infixr 3 type M.Map as >>

type OnePieSeries =
  { name ∷ Maybe String
  , x ∷ Maybe Number
  , y ∷ Maybe Number
  , radius ∷ Maybe Number
  , series ∷ Array DonutSeries
  }

type DonutSeries =
  { radius ∷ Maybe {start ∷ Number, end ∷ Number}
  , name ∷ Maybe String
  , items ∷ String >> Number
  }


buildPieData ∷ PieR → JArray → Array OnePieSeries
buildPieData r records = series
  where
  -- | maybe parallel >> maybe donut >> category name >> values
  dataMap ∷ Maybe String >> Maybe String >> String >> Array Number
  dataMap =
    foldl dataMapFoldFn M.empty records

  dataMapFoldFn
    ∷ Maybe String >> Maybe String >> String >> Array Number
    → Json
    → Maybe String >> Maybe String >> String >> Array Number
  dataMapFoldFn acc js =
    case toString =<< cursorGet r.category js of
      Nothing → acc
      Just categoryKey →
        let
          mbParallel = toString =<< flip cursorGet js =<< r.parallel
          mbDonut = toString =<< flip cursorGet js =<< r.donut
          values = foldMap A.singleton $ toNumber =<< cursorGet r.value js

          alterParallelFn
            ∷ Maybe (Maybe String >> String >> Array Number)
            → Maybe (Maybe String >> String >> Array Number)
          alterParallelFn Nothing =
            Just $ M.singleton mbDonut $ M.singleton categoryKey values
          alterParallelFn (Just donut) =
            Just $ M.alter alterDonutFn mbDonut donut

          alterDonutFn
            ∷ Maybe (String >> Array Number)
            → Maybe (String >> Array Number)
          alterDonutFn Nothing =
            Just $ M.singleton categoryKey values
          alterDonutFn (Just category) =
            Just $ M.alter alterCategoryFn categoryKey category

          alterCategoryFn
            ∷ Maybe (Array Number)
            → Maybe (Array Number)
          alterCategoryFn Nothing = Just values
          alterCategoryFn (Just arr) = Just $ arr ⊕ values
        in
          M.alter alterParallelFn mbParallel acc


  rawSeries ∷ Array OnePieSeries
  rawSeries =
    foldMap mkOnePieSeries $ M.toList dataMap

  mkOnePieSeries
    ∷ Maybe String × (Maybe String >> String >> Array Number)
    → Array OnePieSeries
  mkOnePieSeries (name × donutSeries) =
    [{ name
     , x: Nothing
     , y: Nothing
     , radius: Nothing
     , series: foldMap mkDonutSeries $ M.toList donutSeries
     }]

  mkDonutSeries
    ∷ Maybe String × (String >> Array Number)
    → Array DonutSeries
  mkDonutSeries (name × items) =
    [{ name
     , radius: Nothing
     , items: map (Ag.runAggregation r.valueAggregation) items
     }]

  series ∷ Array OnePieSeries
  series = adjustPosition $ map (\x → x{series = adjustDonutRadiuses x.series}) rawSeries

  adjustPosition ∷ Array OnePieSeries → Array OnePieSeries
  adjustPosition a = a

  adjustDonutRadiuses ∷ Array DonutSeries → Array DonutSeries
  adjustDonutRadiuses a = a

buildPie ∷ PieR → JArray → DSL OptionI
buildPie r records = do
  E.tooltip E.triggerItem

  E.colors colors

  E.legend do
    E.leftLeft
    E.textStyle do
      E.fontSize 12
      E.fontFamily "Ubuntu, sans"
    E.orient ET.Vertical
    E.items $ map ET.strItem legendNames

  E.series series

  E.titles
    $ traverse_ E.title titles

  where
  pieData ∷ Array OnePieSeries
  pieData = buildPieData r records

  legendNames ∷ Array String
  legendNames =
    A.fromFoldable
      $ foldMap (_.series
                 ⋙ foldMap (_.items
                            ⋙ M.keys
                            ⋙ Set.fromFoldable)
                )
        pieData

  series ∷ ∀ i. DSL (pie ∷ ETP.I|i)
  series = for_ pieData \{x, y, radius, series} →
    for_ series \{radius, items, name} → E.pie do
      E.buildCenter do
        traverse_ (E.setX ∘ E.percents) x
        traverse_ (E.setY ∘ E.percents) y

      for_ radius \{start, end} →
        E.buildRadius do
          E.setStart $ E.percents start
          E.setEnd $ E.percents end

      for_ name E.name

      E.buildItems $ for_ (M.toList $ items) \(key × value) →
        E.addItem do
          E.value value
          E.name key

  titles ∷ Array (DSL ETP.TitleI)
  titles = pieData <#> \{name, x, y, radius} → do
    for_ name E.text
    E.textStyle do
      E.fontFamily "Ubuntu, sans"
      E.fontSize 12
    traverse_ (E.top ∘ ET.Percent) y
    traverse_ (E.left ∘ ET.Percent) x
    E.textCenter
    E.textBottom
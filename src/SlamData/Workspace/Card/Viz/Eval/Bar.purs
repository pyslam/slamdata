{-
Copyright 2016 SlamData, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-}

module SlamData.Workspace.Card.Viz.Eval.Bar where

import SlamData.Prelude

import Data.Argonaut (Json, decodeJson, (.?))
import Data.Array as A
import Data.Lens ((^?), (?~))
import Data.Map as Map
import Data.Set as Set
import Data.Variant as V
import ECharts.Commands as E
import ECharts.Monad (DSL)
import ECharts.Types as ET
import ECharts.Types.Phantom (OptionI)
import ECharts.Types.Phantom as ETP
import SlamData.Workspace.Card.CardType as CT
import SlamData.Workspace.Card.Error as CE
import SlamData.Workspace.Card.Eval.Common as CEC
import SlamData.Workspace.Card.Eval.Monad as CEM
import SlamData.Workspace.Card.Port as Port
import SlamData.Workspace.Card.Setups.Auxiliary.Bar as Bar
import SlamData.Workspace.Card.Setups.Axis (Axes)
import SlamData.Workspace.Card.Setups.Axis as Ax
import SlamData.Workspace.Card.Setups.Chart.Common.Brush as CCB
import SlamData.Workspace.Card.Setups.ColorScheme (colors)
import SlamData.Workspace.Card.Setups.Common.Eval (type (>>))
import SlamData.Workspace.Card.Setups.Common.Eval as BCE
import SlamData.Workspace.Card.Setups.Common.Positioning as BCP
import SlamData.Workspace.Card.Setups.Common.Tooltip as CCT
import SlamData.Workspace.Card.Setups.Dimension as D
import SlamData.Workspace.Card.Setups.DimensionMap.Projection as P
import SlamData.Workspace.Card.Setups.Semantics as Sem
import SlamData.Workspace.Card.Setups.Viz.Eval.Common (VizEval)
import SlamData.Workspace.Card.Viz.Model as M
import SqlSquared as Sql
import Utils.SqlSquared (all, asRel, variRelation)

type BarSeries =
  { name ∷ Maybe String
  , items ∷ String >> Number
  }

type BarStacks =
  { stack ∷ Maybe String
  , series ∷ Array BarSeries
  }

type Item =
  { measure ∷ Number
  , category ∷ String
  , parallel ∷ Maybe String
  , stack ∷ Maybe String
  }

decodeItem ∷ Json → Either String Item
decodeItem = decodeJson >=> \obj → do
  measure ← map (fromMaybe zero ∘ Sem.maybeNumber) $ obj .? "measure"
  category ← map (fromMaybe "" ∘ Sem.maybeString) $ obj .? "category"
  parallel ← map Sem.maybeString $ obj .? "parallel"
  stack ← map Sem.maybeString $ obj .? "stack"
  pure { measure
       , category
       , parallel
       , stack
       }

eval
  ∷ ∀ m
  . VizEval m
  ( M.ChartModel
  → Port.ChartInstructionsPort
  → m ( Port.Resource × DSL OptionI )
  )
eval m { chartType, dimMap, aux, axes } = do
  var × resource ← CEM.extractResourcePair Port.Initial

  aux' ←
    maybe
      (CE.throw "Missing or incorrect auxiliary model, please contact support")
      pure
      $ V.prj CT._bar =<< aux

  let
    sql = buildSql (M.getEvents m) var

  CEM.CardEnv { path, varMap } ← ask

  outResource ←
    CE.liftQ $ CEC.localEvalResource (Sql.Query empty sql) varMap
  records ←
    CE.liftQ $ CEC.sampleResource path outResource Nothing

  let
    items = buildData records
    options = buildOptions dimMap axes aux' items
  pure $ outResource × options

buildSql ∷ Array M.FilteredEvent → Port.Var → Sql.Sql
buildSql es var =
  Sql.buildSelect
  $ all
  ∘ (Sql._relations
     ?~ (variRelation (unwrap var) # asRel "res"))


buildData ∷ Array Json → Array BarStacks
buildData =
  stacks ∘ foldMap (foldMap A.singleton ∘ decodeItem)
  where
  stacks ∷ Array Item → Array BarStacks
  stacks =
    BCE.groupOn _.stack
      ⋙ map \(stack × items) →
          { stack
          , series: series items
          }
  series ∷ Array Item → Array BarSeries
  series =
    BCE.groupOn _.parallel
      ⋙ map \(name × items) →
          { name
          , items: Map.fromFoldable $ map toPoint items
          }
  toPoint ∷ Item → String × Number
  toPoint { measure, category } = category × measure

buildOptions ∷ P.DimMap → Axes → Bar.State → Array BarStacks → DSL OptionI
buildOptions dimMap axes r barData = do
  let
    mkRow prj value  = P.lookup prj dimMap # foldMap \dim →
      [ { label: D.jcursorLabel dim, value } ]

    cols = A.fold
      [ mkRow P.category $ CCT.formatValueIx 0
      , mkRow P.value $ CCT.formatValueIx 1
      , mkRow P.stack $ CCT.formatNameIx 0
      , mkRow P.parallel $ CCT.formatNameIx
          if P.member P.stack dimMap then 1 else 0
      ]

  CCB.brush

  CCT.tooltip do
    E.formatterItem (CCT.tableFormatter (pure ∘ _.color) cols ∘ pure)
    E.triggerItem

  E.colors colors

  E.xAxis do
    E.axisType ET.Category
    E.enabledBoundaryGap
    E.items $ map ET.strItem xValues
    E.axisLabel do
      traverse_ E.interval xAxisConfig.interval
      E.rotate r.axisLabelAngle
      E.textStyle do
        E.fontFamily "Ubuntu, sans"

  E.yAxis do
    E.axisType ET.Value
    E.axisLabel $ E.textStyle do
      E.fontFamily "Ubuntu, sans"
    E.axisLine $ E.lineStyle $ E.width 1
    E.splitLine $ E.lineStyle $ E.width 1

  E.legend do
    E.textStyle $ E.fontFamily "Ubuntu, sans"
    case xAxisConfig.axisType of
      ET.Category | A.length seriesNames > 40 → E.hidden
      _ → pure unit
    E.items $ map ET.strItem seriesNames
    E.leftLeft
    E.topBottom

  E.grid BCP.cartesian

  E.series series

  where
  xAxisType ∷ Ax.AxisType
  xAxisType = fromMaybe Ax.Category do
    ljc ← P.lookup P.category dimMap
    cursor ← ljc ^? D._value ∘ D._projection
    pure $ Ax.axisType cursor axes

  xAxisConfig ∷ Ax.EChartsAxisConfiguration
  xAxisConfig = Ax.axisConfiguration xAxisType

  seriesNames ∷ Array String
  seriesNames = case P.lookup P.stack dimMap, P.lookup P.parallel dimMap of
    Nothing, Nothing →
      [ ]
    Nothing, Just _ →
      A.fromFoldable
      $ flip foldMap barData
      $ foldMap (Set.fromFoldable ∘ _.name)
      ∘ _.series
    _, _ →
      A.catMaybes $ map _.stack barData

  xValues ∷ Array String
  xValues =
    A.sortBy xSortFn
      $ A.fromFoldable
      $ flip foldMap barData
      $ foldMap (Set.fromFoldable ∘ Map.keys ∘ _.items)
      ∘ _.series

  xSortFn ∷ String → String → Ordering
  xSortFn = Ax.compareWithAxisType xAxisType

  series ∷ ∀ i. DSL (bar ∷ ETP.I|i)
  series = for_ barData \stacked →
    for_ stacked.series \serie → E.bar do
      E.buildItems $ for_ xValues \key →
        case Map.lookup key serie.items of
          Nothing → E.missingItem
          Just v → E.addItem do
            E.buildNames do
              for_ stacked.stack $ E.addName
              for_ serie.name $ E.addName
              E.addName $ "key:" ⊕ key
            E.buildValues do
              E.addStringValue key
              E.addValue v
      for_ stacked.stack E.name
      case P.lookup P.parallel dimMap, P.lookup P.stack dimMap of
        Just _, Nothing →
          for_ serie.name E.name
        Just _, Just _ →
          for_ serie.name E.stack
        _, _ →
          E.stack "default stack"
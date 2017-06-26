module SlamData.Workspace.Card.Setups.Viz.Eval
  ( eval
  , module SlamData.Workspace.Card.Setups.Viz.Model
  ) where

import SlamData.Prelude

import Color as C

import Control.Alternative (class Alternative)
import Control.Monad.State (class MonadState, get, put)
import Control.Monad.Writer.Class (class MonadTell)

import Data.Array ((!!))
import Data.Array as A
import Data.String as Str
import Data.Formatter.Number as FN
import Data.Argonaut (decodeJson, (.?), Json)
import Data.Map as M
import Data.List as L
import Data.Variant (prj)
import Data.StrMap as SM
import Data.Lens (preview)
import Data.Set as Set
import Data.String.Regex as Rgx
import Data.String.Regex.Flags as RXF
import Data.Int as Int

import ECharts.Monad (DSL)
import ECharts.Commands as E
import ECharts.Types as ET
import ECharts.Types.Phantom (OptionI)
import ECharts.Types.Phantom as ETP

import SlamData.Workspace.Card.Port as Port
import SlamData.Workspace.Card.Setups.Viz.Model (Model)
import SlamData.Workspace.Card.Setups.Chart.ColorScheme (colors, getShadeColor)
import SlamData.Workspace.Card.Setups.Common.Eval as BCE
import SlamData.Workspace.Card.Setups.Chart.Common.Tooltip as CCT
import SlamData.Workspace.Card.Error as CE
import SlamData.Workspace.Card.Setups.Chart.Common.Positioning as BCP
import SlamData.Workspace.Card.Setups.Viz.Error as VE
import SlamData.Workspace.Card.Eval.Monad as CEM
import SlamData.Quasar.Class (class QuasarDSL)
import SlamData.Workspace.Card.Setups.Package.Types as P
import SlamData.Workspace.Card.CardType.ChartType as CT
--import SlamData.Workspace.Card.Setups.Transform as T
--import SlamData.Workspace.Card.Setups.Transform.Aggregation as Ag
import SlamData.Workspace.Card.CardType.VizType as VT
import SlamData.Workspace.Card.Setups.DimMap.Component.State as DS
import SlamData.Workspace.Card.Setups.Dimension as D
import SlamData.Workspace.Card.Setups.Package.Projection as PP
import SlamData.Workspace.Card.Setups.Axis as Ax
import SlamData.Workspace.Card.Setups.Chart.Common as SCC
import SlamData.Workspace.Card.Setups.Semantics as Sem
import SlamData.Workspace.Card.Setups.Chart.Area.Eval as Area
import SlamData.Workspace.Card.Setups.Chart.Bar.Eval as Bar
import SlamData.Workspace.Card.Setups.Chart.Boxplot.Eval as Boxplot
import SlamData.Workspace.Card.Setups.Chart.Candlestick.Eval as Candlestick
import SlamData.Workspace.Card.Setups.Viz.Auxiliary as Aux
--import SlamData.Workspace.Card.Setups.Common.Eval as BCE

import SqlSquared as Sql

import Utils.Foldable (enumeratedFor_)

type VizEval m v =
  MonadState CEM.CardState m
  ⇒ MonadThrow CE.CardError m
  ⇒ MonadAsk CEM.CardEnv m
  ⇒ MonadTell CEM.CardLog m
  ⇒ QuasarDSL m
  ⇒ Model
  → Port.Resource
  → m Port.Out

eval ∷ ∀ m v. VizEval m v
eval m resource = do
  records × axes ← BCE.analyze resource =<< get
  put $ Just $ CEM.Analysis { resource, records, axes }

  unless (L.null missingProjections)
    $ VE.throw $ { missingProjections, vizType }
  when (isNothing var)
    $ CE.throw "Auxiliary model is not provided, please contact support"
  unless auxFitsVizType
    $ CE.throw "Auxiliary model is incorrect, please contact support"

  case vizType of
    VT.Metric →
      if (maybe false (flip Ax.isValue axes)
          $ P.getProjection dimMap PP._value >>= preview (D._value ∘ D._projection))
      then
        evalMetric m resource
      else
        evalStaticForm records m resource
    VT.Chart VT.Area →
      evalArea m resource
    VT.Chart VT.Bar →
      evalBar m resource
    VT.Chart VT.Boxplot →
      evalBoxplot m resource
    VT.Chart VT.Candlestick →
      evalCandlestick m resource
    _ →
      CE.throw "not implemented here yet"

  where
  vizType ∷ VT.VizType
  vizType = m.vizType

  var ∷ Maybe Aux.State
  var = M.lookup vizType m.auxes

  auxFitsVizType ∷ Boolean
  auxFitsVizType = case vizType of
    VT.Geo VT.GeoHeatmap → isJust $ prj Aux._geoHeatmap =<< var
    VT.Geo VT.GeoMarker → isJust $ prj Aux._geoMarker =<< var
    VT.Chart VT.Area → isJust $ prj Aux._area =<< var
    VT.Chart VT.Bar → isJust $ prj Aux._bar =<< var
    VT.Chart VT.Funnel → isJust $ prj Aux._funnel =<< var
    VT.Chart VT.Graph → isJust $ prj Aux._graph =<< var
    VT.Chart VT.Heatmap → isJust $ prj Aux._heatmap =<< var
    VT.Chart VT.Line → isJust $ prj Aux._line =<< var
    VT.Metric → isJust $ prj Aux._metric =<< var
    VT.Chart VT.PunchCard → isJust $ prj Aux._punchCard =<< var
    VT.Chart VT.Scatter → isJust $ prj Aux._scatter =<< var
    _ → true


  requiredProjections ∷ L.List P.Projection
  requiredProjections = foldMap _.requiredFields $ M.lookup vizType DS.packages

  missingProjections ∷ L.List P.Projection
  missingProjections = L.filter (not ∘ P.hasProjection dimMap) requiredProjections

  dimMap ∷ P.DimensionMap
  dimMap = fromMaybe P.emptyDimMap $ M.lookup m.vizType m.dimMaps

evalMetric ∷ ∀ m v. VizEval m v
evalMetric m =
  BCE.chartSetupEval buildSql buildPort
  $ M.lookup m.vizType m.auxes >>= prj Aux._metric
  where
  dimMap = fromMaybe P.emptyDimMap $ M.lookup m.vizType m.dimMaps

  buildSql = SCC.buildBasicSql buildProjections buildGroupBy

  buildPort ∷ { formatter ∷ String } → Ax.Axes → Port.Port
  buildPort { formatter } _ =
    Port.BuildMetric \json → do
      obj ← decodeJson json
      metricValue ← obj .? "value"
      let value = reifyValue metricValue formatter
      pure { value, label }

  buildProjections ∷ ∀ a. a → L.List (Sql.Projection Sql.Sql)
  buildProjections _ = pure $ case P.getProjection dimMap PP._value of
    Nothing → SCC.nullPrj # Sql.as "value"
    Just sv → sv # SCC.jcursorPrj # Sql.as "value" # SCC.applyTransform sv

  buildGroupBy ∷ ∀ a. a → Maybe (Sql.GroupBy Sql.Sql)
  buildGroupBy = const Nothing

  label ∷ Maybe String
  label = map D.jcursorLabel $ P.getProjection dimMap PP._value

  formatterRegex ∷ Rgx.Regex
  formatterRegex =
    unsafePartial fromRight $ Rgx.regex "{{[^}]+}}" RXF.noFlags

  reifyValue ∷ Number → String → String
  reifyValue metricValue input = fromMaybe (show metricValue) do
    matches ← Rgx.match formatterRegex input
    firstMatch ← join $ A.head matches
    woPrefix ← Str.stripPrefix (Str.Pattern "{{") firstMatch
    formatString ← Str.stripSuffix (Str.Pattern "}}") woPrefix
    formatter ← either (const Nothing) Just $ FN.parseFormatString formatString
    let
      formattedNumber = FN.format formatter metricValue

    pure $ Rgx.replace formatterRegex formattedNumber input

evalStaticForm ∷ ∀ m v. Array Json → VizEval m v
evalStaticForm records m resource = do
  pure $ port × (SM.singleton Port.defaultResourceVar $ Left resource)
  where
  port = Port.CategoricalMetric { value, label: Nothing }
  value = fromMaybe "" do
    record ← A.head records
    dimMap ← M.lookup m.vizType m.dimMaps
    dim ← P.getProjection dimMap PP._value
    cursor ← preview (D._value ∘ D._projection) dim
    Sem.getMaybeString record cursor


evalArea ∷ ∀ m v. VizEval m v
evalArea m =
  BCE.chartSetupEval buildSql buildPort
  $ M.lookup m.vizType m.auxes >>= prj Aux._area
  where
  dimMap = fromMaybe P.emptyDimMap $ M.lookup m.vizType m.dimMaps

  buildSql = SCC.buildBasicSql buildProjections buildGroupBy

  buildProjections _ = L.fromFoldable $ A.concat
    [ measureProjection PP._value dimMap "measure"
    , dimensionProjection PP._dimension dimMap "dimension"
    , dimensionProjection PP._series dimMap "series"
    ]

  buildGroupBy r =
    SCC.groupBy
    $ sqlProjection PP._series dimMap
    <|> sqlProjection PP._dimension dimMap


  buildPort r axes =
    Port.ChartInstructions
      { options: areaOptions dimMap axes r ∘ Area.buildAreaData
        -- TODO: this should be removed
      , chartType: CT.Pie
      }
evalBar ∷ ∀ m v. VizEval m v
evalBar m =
  BCE.chartSetupEval buildSql buildPort
  $ M.lookup m.vizType m.auxes >>= prj Aux._bar
  where
  dimMap = fromMaybe P.emptyDimMap $ M.lookup m.vizType m.dimMaps

  buildSql = SCC.buildBasicSql buildProjections buildGroupBy

  buildProjections _ = L.fromFoldable $ A.concat
    [ measureProjection PP._value dimMap "measure"
    , dimensionProjection PP._category dimMap "category"
    , dimensionProjection PP._stack dimMap "stack"
    , dimensionProjection PP._parallel dimMap "parallel"
    ]

  buildGroupBy _ =
    SCC.groupBy
    $ sqlProjection PP._parallel dimMap
    <|> sqlProjection PP._stack dimMap
    <|> sqlProjection PP._category dimMap

  buildPort r axes =
    Port.ChartInstructions
      { options: barOptions dimMap axes r ∘ Bar.buildBarData
        -- TODO: this should be removed
      , chartType: CT.Pie
      }


sqlProjection
  ∷ ∀ m
  . Alternative m
  ⇒ P.Projection
  → P.DimensionMap
  → m Sql.Sql
sqlProjection projection dimMap =
  P.getProjection dimMap projection
  <#> SCC.jcursorSql
  # maybe empty pure


dimensionProjection
  ∷ ∀ m
  . Applicative m
  ⇒ P.Projection
  → P.DimensionMap
  → String
  → m (Sql.Projection Sql.Sql)
dimensionProjection projection dimMap label =
  P.getProjection dimMap projection
  # maybe SCC.nullPrj SCC.jcursorPrj
  # Sql.as label
  # pure

measureProjection
  ∷ ∀ m
  . Applicative m
  ⇒ P.Projection
  → P.DimensionMap
  → String
  → m (Sql.Projection Sql.Sql)
measureProjection projection dimMap label = pure case P.getProjection dimMap projection of
  Nothing → SCC.nullPrj # Sql.as label
  Just sv → sv # SCC.jcursorPrj # Sql.as label # SCC.applyTransform sv

areaOptions ∷ P.DimensionMap → Ax.Axes → Aux.AreaState → Array Area.AreaSeries → DSL OptionI
areaOptions dimMap axes r areaData = do
  let
    mkLabel dimPrj axesPrj = flip foldMap (P.getProjection dimMap dimPrj) \dim →
      [ { label: D.jcursorLabel dim, value: axesPrj } ]

    cols = A.fold
      [ mkLabel PP._dimension $ CCT.formatValueIx 0
      , mkLabel PP._value $ CCT.formatValueIx 1
      , mkLabel PP._series _.seriesName
      ]

  E.tooltip do
    E.formatterItem $ CCT.tableFormatter (pure ∘ _.color) cols ∘ pure
    E.triggerItem
    E.textStyle do
      E.fontFamily "Ubuntu, sans"
      E.fontSize 12
    E.axisPointer do
      E.lineAxisPointer
      E.lineStyle do
        E.width 1
        E.solidLine

  E.yAxis do
    E.axisType ET.Value
    E.axisLabel $ E.textStyle do
      E.fontFamily "Ubuntu, sans"
    E.axisLine $ E.lineStyle do
      E.width 1
    E.splitLine $ E.lineStyle do
      E.width 1

  E.xAxis do
    E.axisType xAxisConfig.axisType
    traverse_ E.interval $ xAxisConfig.interval
    case xAxisConfig.axisType of
      ET.Category →
        E.items $ map ET.strItem xValues
      _ → pure unit
    E.disabledBoundaryGap
    E.axisTick do
      E.length 2
      E.lineStyle do
        E.width 1
    E.splitLine $ E.lineStyle do
      E.width 1
    E.axisLine $ E.lineStyle do
      E.width 1
    E.axisLabel do
      E.rotate r.axisLabelAngle
      E.textStyle do
        E.fontFamily "Ubuntu, sans"

  E.colors colors

  E.grid BCP.cartesian

  E.legend do
    E.textStyle $ E.fontFamily "Ubuntu, sans"
    E.items $ map ET.strItem seriesNames

  E.series series

  where
  xAxisType ∷ Ax.AxisType
  xAxisType =
    fromMaybe Ax.Category
    $ Ax.axisType <$> (P.getProjection dimMap PP._dimension >>= preview (D._value ∘ D._projection))
    <*> pure axes

  xAxisConfig ∷ Ax.EChartsAxisConfiguration
  xAxisConfig = Ax.axisConfiguration xAxisType

  xSortFn ∷ String → String → Ordering
  xSortFn = Ax.compareWithAxisType xAxisType

  xValues ∷ Array String
  xValues =
    A.sortBy xSortFn
      $ A.fromFoldable
      $ foldMap (_.items ⋙ M.keys ⋙ Set.fromFoldable)
        areaData

  seriesNames ∷ Array String
  seriesNames =
    A.fromFoldable
      $ foldMap (_.name ⋙ Set.fromFoldable)
        areaData

  series ∷ ∀ i. DSL (line ∷ ETP.I|i)
  series = enumeratedFor_ areaData \(ix × serie) → E.line do
    E.buildItems $ for_ xValues \key → do
      case M.lookup key serie.items of
        Nothing → E.missingItem
        Just v → E.addItem do
          E.name key
          E.buildValues do
            E.addStringValue key
            E.addValue v
          E.symbolSize $ Int.floor r.size
    for_ serie.name E.name
    for_ (colors !! ix) \color → do
      E.itemStyle $ E.normal $ E.color color
      E.areaStyle $ E.normal $ E.color $ getShadeColor color (if r.isStacked then 1.0 else 0.5)
    E.lineStyle $ E.normal $ E.width 2
    E.symbol ET.Circle
    E.smooth r.isSmooth
    when r.isStacked $ E.stack "stack"

barOptions ∷ P.DimensionMap → Ax.Axes → Aux.BarState → Array Bar.BarStacks → DSL OptionI
barOptions dimMap axes r barData = do
  let
    mkLabel dimPrj axesPrj = flip foldMap (P.getProjection dimMap dimPrj) \dim →
      [ { label: D.jcursorLabel dim, value: axesPrj } ]

    cols = A.fold
      [ mkLabel PP._category $ CCT.formatValueIx 0
      , mkLabel PP._value $ CCT.formatValueIx 1
      , mkLabel PP._stack $ CCT.formatNameIx 0
      , mkLabel PP._parallel $ CCT.formatNameIx
          if P.hasProjection dimMap PP._stack then 1 else 0
      ]

  E.tooltip do
    E.formatterItem (CCT.tableFormatter (pure ∘ _.color) cols ∘ pure)
    E.textStyle $ E.fontSize 12
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
  xAxisType =
    fromMaybe Ax.Category
    $ Ax.axisType
    <$> (P.getProjection dimMap PP._category >>= preview (D._value ∘ D._projection))
    <*> pure axes


  xAxisConfig ∷ Ax.EChartsAxisConfiguration
  xAxisConfig = Ax.axisConfiguration xAxisType

  seriesNames ∷ Array String
  seriesNames = case P.getProjection dimMap PP._stack, P.getProjection dimMap PP._parallel of
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
      $ foldMap (Set.fromFoldable ∘ M.keys ∘ _.items)
      ∘ _.series


  xSortFn ∷ String → String → Ordering
  xSortFn = Ax.compareWithAxisType xAxisType

  series ∷ ∀ i. DSL (bar ∷ ETP.I|i)
  series = for_ barData \stacked →
    for_ stacked.series \serie → E.bar do
      E.buildItems $ for_ xValues \key →
        case M.lookup key serie.items of
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
      case P.hasProjection dimMap PP._parallel, P.hasProjection dimMap PP._stack of
        true, false →
          for_ serie.name E.name
        true, true →
          for_ serie.name E.stack
        _, _ →
          E.stack "default stack"

evalBoxplot ∷ ∀ m v. VizEval m v
evalBoxplot m =
  BCE.chartSetupEval buildSql buildPort Nothing
  where
  dimMap = fromMaybe P.emptyDimMap $ M.lookup m.vizType m.dimMaps

  buildSql = SCC.buildBasicSql buildProjections buildGroupBy

  buildProjections _ = L.fromFoldable $ A.concat
    [ dimensionProjection PP._value dimMap "measure"
    , dimensionProjection PP._dimension dimMap "dimension"
    , dimensionProjection PP._series dimMap "series"
    , dimensionProjection PP._parallel dimMap "parallel"
    ]

  buildGroupBy _ = Nothing


  buildPort r axes =
    Port.ChartInstructions
      { options: boxplotOptions dimMap axes r ∘ Boxplot.buildBoxplotData
        -- TODO: this should be removed
      , chartType: CT.Pie
      }

boxplotOptions ∷ P.DimensionMap → Ax.Axes → Void → Array Boxplot.OnOneBoxplot → DSL OptionI
boxplotOptions dimMap axes r boxplotData = do
  E.tooltip do
    E.triggerItem
    E.textStyle do
      E.fontFamily "Ubuntu, sans"
      E.fontSize 12

  BCP.rectangularTitles boxplotData
    $ maybe "" D.jcursorLabel $ P.getProjection dimMap PP._parallel

  BCP.rectangularGrids boxplotData


  E.legend do
    E.topBottom
    E.textStyle $ E.fontFamily "Ubuntu, sans"
    E.items $ map ET.strItem serieNames

  E.xAxes xAxes

  E.yAxes yAxes

  E.series series

  where
  serieNames ∷ Array String
  serieNames =
    A.fromFoldable
    $ flip foldMap boxplotData
    $ foldMap (Set.fromFoldable ∘ _.name)
    ∘ _.series

  series = enumeratedFor_ boxplotData \(ix × onOnePlot) → for_ onOnePlot.series \serie → do
    E.boxPlot $ boxplotSerie $ ix × serie
    E.scatter $ scatterSerie $ ix × serie

  boxplotSerie (ix × serie) = do
    for_ serie.name E.name

    E.xAxisIndex ix
    E.yAxisIndex ix

    E.itemStyle $ E.normal do
      E.borderWidth 2
      E.borderColor
        $ fromMaybe (C.rgba 0 0 0 0.5)
        $ serie.name
        >>= flip A.elemIndex serieNames
        >>= (colors !! _)

    E.tooltip $ E.formatterItem \item →
      CCT.tableRows $ A.fold
      [ flip foldMap (P.getProjection dimMap PP._dimension) \dim →
         [ D.jcursorLabel dim × item.name ]
      , [ "Upper" × CCT.formatNumberValueIx 4 item ]
      , [ "Q3" × CCT.formatNumberValueIx 3 item ]
      , [ "Median" × CCT.formatNumberValueIx 2 item ]
      , [ "Q1" × CCT.formatNumberValueIx 1 item ]
      , [ "Lower" × CCT.formatNumberValueIx 0 item ]
      ]

    E.buildItems
      $ for_ xAxisLabels \key → case M.lookup key serie.items of
        Nothing → E.missingItem
        Just (_ × mbBP) → for_ mbBP \item → E.addItem $ E.buildValues do
          E.addValue item.low
          E.addValue item.q1
          E.addValue item.q2
          E.addValue item.q3
          E.addValue item.high


  scatterSerie (ix × serie) = do
    for_ serie.name E.name
    E.xAxisIndex ix
    E.yAxisIndex ix
    E.symbolSize
      if isNothing serie.name ∨ serie.name ≡ Just ""
        then 5
        else 0
    E.itemStyle $ E.normal
      $ E.color
      $ fromMaybe (C.rgba 0 0 0 0.5)
      $ serie.name
      >>= flip A.elemIndex serieNames
      >>= (colors !! _)

    E.tooltip $ E.formatterItem\param →
      param.name ⊕ "<br/>"
      ⊕ CCT.formatNumberValueIx 0 param

    E.buildItems
      $ enumeratedFor_ serie.items \(ox × (outliers × _)) →
          for_ outliers \outlier → E.addItem $ E.buildValues do
            E.addValue $ Int.toNumber ox
            E.addValue outlier

  grids ∷ Array (DSL ETP.GridI)
  grids = boxplotData <#> \{x, y, w, h} → do
    for_ x $ E.left ∘ ET.Percent
    for_ y $ E.top ∘ ET.Percent
    for_ w E.widthPct
    for_ h E.heightPct

  titles ∷ Array (DSL ETP.TitleI)
  titles = boxplotData <#> \{x, y, name, fontSize} → do
    for_ name E.text
    E.textStyle do
      E.fontFamily "Ubuntu, sans"
      for_ fontSize E.fontSize
    for_ x $ E.left ∘ ET.Percent
    for_ y $ E.top ∘ ET.Percent
    E.textCenter
    E.textMiddle

  xAxisLabels ∷ Array String
  xAxisLabels =
    A.fromFoldable
    $ flip foldMap boxplotData
    $ foldMap (Set.fromFoldable ∘ M.keys ∘ _.items)
    ∘ _.series

  xAxes = enumeratedFor_ boxplotData \(ix × _) → E.addXAxis do
    E.gridIndex ix
    E.axisType ET.Category
    E.axisLabel do
      E.textStyle do
        E.fontFamily "Ubuntu, sans"
    E.axisLine $ E.lineStyle do
      E.width 1
    E.splitLine $ E.lineStyle do
      E.width 1
    E.splitArea E.hidden
    E.items $ map ET.strItem xAxisLabels


  yAxes = enumeratedFor_ boxplotData \(ix × _) → E.addYAxis do
    E.gridIndex ix
    E.axisType ET.Value
    E.axisLabel do
      E.textStyle do
        E.fontFamily "Ubuntu, sans"
    E.axisLine $ E.lineStyle do
      E.width 1
    E.splitLine $ E.lineStyle do
      E.width 1
    E.splitArea E.hidden

evalCandlestick ∷ ∀ m v. VizEval m v
evalCandlestick m =
  BCE.chartSetupEval buildSql buildPort Nothing
  where
  dimMap = fromMaybe P.emptyDimMap $ M.lookup m.vizType m.dimMaps

  buildSql = SCC.buildBasicSql buildProjections buildGroupBy

  buildProjections _ = L.fromFoldable $ A.concat
    [ dimensionProjection PP._dimension dimMap "dimension"
    , measureProjection PP._high dimMap "high"
    , measureProjection PP._low dimMap "low"
    , measureProjection PP._open dimMap "open"
    , measureProjection PP._close dimMap "close"
    , dimensionProjection PP._parallel dimMap "parallel"
    ]

  buildGroupBy _ =
    SCC.groupBy
    $ sqlProjection PP._parallel dimMap
    <|> sqlProjection PP._dimension dimMap

  buildPort r axes =
    Port.ChartInstructions
      { options: kOptions dimMap axes r ∘ Candlestick.buildKData
        -- TODO: this should be removed
      , chartType: CT.Pie
      }
kOptions ∷ P.DimensionMap → Ax.Axes → Void → Array Candlestick.OnOneGrid → DSL OptionI
kOptions dimMap axes _ kData = do
  E.tooltip do
    E.triggerItem
    E.textStyle do
      E.fontFamily "Ubuntu, sans"
      E.fontSize 12
    E.formatterItem \fmt →
      let mkRow prj f =
            P.getProjection dimMap prj
            # foldMap \dim →
            [ D.jcursorLabel dim × f ]
      in CCT.tableRows $ A.fold
          [ mkRow PP._dimension fmt.name
          , mkRow PP._open $ CCT.formatValueIx 0 fmt
          , mkRow PP._close $ CCT.formatValueIx 1 fmt
          , mkRow PP._low $ CCT.formatValueIx 2 fmt
          , mkRow PP._high $ CCT.formatValueIx 2 fmt
          ]


  BCP.rectangularTitles kData
    $ maybe "" D.jcursorLabel $ P.getProjection dimMap PP._parallel
  BCP.rectangularGrids kData

  E.colors colors

  E.xAxes xAxes
  E.yAxes yAxes
  E.series series

  where
  xValues ∷ Candlestick.OnOneGrid → Array String
  xValues  = sortX ∘ foldMap A.singleton ∘ M.keys ∘ _.items

  xAxisType ∷ Ax.AxisType
  xAxisType =
    fromMaybe Ax.Category
    $ Ax.axisType <$> (P.getProjection dimMap PP._dimension >>= preview  (D._value ∘ D._projection))
    <*> pure axes


  sortX ∷ Array String → Array String
  sortX = A.sortBy $ Ax.compareWithAxisType xAxisType

  xAxes = enumeratedFor_ kData \(ix × serie) → E.addXAxis do
    E.gridIndex ix
    E.axisType ET.Category
    E.axisLabel $ E.textStyle $ E.fontFamily "Ubuntu, sans"
    E.items $ map ET.strItem $ xValues serie

  yAxes = enumeratedFor_ kData \(ix × _) → E.addYAxis do
    E.gridIndex ix
    E.axisType ET.Value

  series = enumeratedFor_  kData \(ix × serie) → E.candlestick do
    for_ serie.name E.name
    E.xAxisIndex ix
    E.yAxisIndex ix
    E.buildItems $ for_ (xValues serie) \dim →
      for_ (M.lookup dim serie.items) \{high, low, open, close} → E.addItem $ E.buildValues do
        E.addValue open
        E.addValue close
        E.addValue low
        E.addValue high

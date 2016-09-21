module SlamData.Workspace.Card.BuildChart.Area.Component
  ( areaBuilderComponent
  ) where

import SlamData.Prelude

import Data.Argonaut (JCursor)
import Data.Lens (view, (^?), (.~))
import Data.Lens as Lens
import Data.Int as Int

import Global (readFloat, isNaN)

import Halogen as H
import Halogen.Component.ChildPath (ChildPath, cpL, cpR, (:>))
import Halogen.HTML.Indexed as HH
import Halogen.CustomProps as Cp
import Halogen.HTML.Events.Indexed as HE
import Halogen.HTML.Properties.Indexed as HP
import Halogen.HTML.Properties.Indexed.ARIA as ARIA
import Halogen.Themes.Bootstrap3 as B

import SlamData.Monad (Slam)
import SlamData.Workspace.Card.Model as Card
import SlamData.Workspace.Card.Port as Port
import SlamData.Render.Common (row)
import SlamData.Form.Select
  ( Select
  , newSelect
  , emptySelect
  , setPreviousValueFrom
  , autoSelect
  , ifSelected
  , (⊝)
  , _value
  , trySelect'
  , fromSelected
  )
import SlamData.Workspace.LevelOfDetails (LevelOfDetails(..))
import SlamData.Workspace.Card.Component as CC
import SlamData.Workspace.Card.Common.Render (renderLowLOD)
import SlamData.Workspace.Card.CardType as CT
import SlamData.Workspace.Card.CardType.ChartType as CHT
import SlamData.Workspace.Card.CardType.ChartType (ChartType(..))
import SlamData.Workspace.Card.Chart.ChartConfiguration (depends, dependsOnArr)
import SlamData.Form.Select.Component as S
import SlamData.Form.SelectPair.Component as P
import SlamData.Workspace.Card.Chart.Axis (Axes)
import SlamData.Workspace.Card.Chart.Aggregation (Aggregation, nonMaybeAggregationSelect)

import SlamData.Workspace.Card.BuildChart.CSS as CSS
import SlamData.Workspace.Card.BuildChart.Area.Component.ChildSlot as CS
import SlamData.Workspace.Card.BuildChart.Area.Component.State as ST
import SlamData.Workspace.Card.BuildChart.Area.Component.Query as Q
import SlamData.Workspace.Card.BuildChart.Area.Model as M

type DSL =
  H.ParentDSL ST.State CS.ChildState Q.QueryC CS.ChildQuery Slam CS.ChildSlot

type HTML =
  H.ParentHTML CS.ChildState Q.QueryC CS.ChildQuery Slam CS.ChildSlot

areaBuilderComponent ∷ H.Component CC.CardStateP CC.CardQueryP Slam
areaBuilderComponent = CC.makeCardComponent
  { cardType: CT.ChartOptions CHT.Area
  , component: H.parentComponent { render, eval, peek: Just (peek ∘ H.runChildF) }
  , initialState: H.parentState ST.initialState
  , _State: CC._BuildAreaState
  , _Query: CC.makeQueryPrism' CC._BuildAreaQuery
  }

render ∷ ST.State → HTML
render state =
  HH.div_
    [ renderHighLOD state
    , renderLowLOD (CT.darkCardGlyph $ CT.ChartOptions CHT.Area) left state.levelOfDetails
    ]

renderHighLOD ∷ ST.State → HTML
renderHighLOD state =
  HH.div
    [ HP.classes
        $ [ CSS.chartEditor ]
        ⊕ (guard (state.levelOfDetails ≠ High) $> B.hidden)
    ]
    [ renderDimension state
    , HH.hr_
    , renderValue state
    , renderSecondValue state
    , HH.hr_
    , renderSeries state
    , HH.hr_
    , row [ renderIsStacked state, renderIsSmooth state ]
    , row [ renderAxisLabelAngle state, renderAxisLabelFontSize state ]
    ]


renderDimension ∷ ST.State → HTML
renderDimension state =
  HH.form
    [ HP.classes [ CSS.chartConfigureForm ]
    , Cp.nonSubmit
    ]
    [ HH.label [ HP.classes [ B.controlLabel ] ] [ HH.text "Dimension" ]
    , HH.slot' CS.cpDimension unit \_ →
         { component: S.primarySelect (Just "Dimension")
         , initialState: emptySelect
         }
    ]

renderValue ∷ ST.State → HTML
renderValue state =
  HH.form
    [ HP.classes [ CSS.withAggregation, CSS.chartConfigureForm ]
    , Cp.nonSubmit
    ]
    [ HH.label [ HP.classes [ B.controlLabel ] ] [ HH.text "Measure" ]
    , HH.slot' CS.cpValue unit \_ →
       { component:
           P.selectPair { disableWhen: (_ < 1)
                        , defaultWhen: (const true)
                        , mainState: emptySelect
                        , ariaLabel: Just "Measure"
                        , classes: [ B.btnPrimary, CSS.aggregation]
                        , defaultOption: "Select axis source"
                        }
       , initialState: H.parentState $ P.initialState nonMaybeAggregationSelect
       }
    ]

renderSecondValue ∷ ST.State → HTML
renderSecondValue state =
  HH.form
    [ HP.classes [ CSS.withAggregation, CSS.chartConfigureForm ]
    , Cp.nonSubmit
    ]
    [ HH.label [ HP.classes [ B.controlLabel ] ] [ HH.text "Measure" ]
    , HH.slot' CS.cpSecondValue unit \_ →
       { component:
           P.selectPair { disableWhen: (_ < 2)
                        , defaultWhen: (_ > 1)
                        , mainState: emptySelect
                        , ariaLabel: Just "Measure"
                        , classes: [ B.btnPrimary, CSS.aggregation]
                        , defaultOption: "Select axis source"
                        }
       , initialState: H.parentState $ P.initialState nonMaybeAggregationSelect
       }
    ]

renderSeries ∷ ST.State → HTML
renderSeries state =
  HH.form
    [ HP.classes [ CSS.chartConfigureForm ]
    , Cp.nonSubmit
    ]
    [ HH.label [ HP.classes [ B.controlLabel ] ] [ HH.text "Series" ]
    , HH.slot' CS.cpSeries unit \_ →
       { component: S.secondarySelect (pure "Series")
       , initialState: emptySelect
       }
    ]

renderAxisLabelAngle ∷ ST.State → HTML
renderAxisLabelAngle state =
  HH.form
    [ HP.classes [ B.colXs6, CSS.axisLabelParam ]
    , Cp.nonSubmit
    ]
    [ HH.label [ HP.classes [ B.controlLabel ] ] [ HH.text "Axis label angle" ]
    , HH.input
        [ HP.classes [ B.formControl ]
        , HP.value $ show $ state.axisLabelAngle
        , ARIA.label "Axis label angle"
        , HE.onValueChange $ HE.input (\s → right ∘ Q.SetAxisLabelAngle s)
        ]
    ]

renderAxisLabelFontSize ∷ ST.State → HTML
renderAxisLabelFontSize state =
  HH.form
    [ HP.classes [ B.colXs6, CSS.axisLabelParam ]
    , Cp.nonSubmit
    ]
    [ HH.label [ HP.classes [ B.controlLabel ] ] [ HH.text "Axis label font size" ]
    , HH.input
        [ HP.classes [ B.formControl ]
        , HP.value $ show $ state.axisLabelFontSize
        , ARIA.label "Axis label font size"
        , HE.onValueChange $ HE.input (\s → right ∘ Q.SetAxisLabelFontSize s)
        ]
    ]

renderIsStacked ∷ ST.State → HTML
renderIsStacked state =
  HH.form
    [ HP.classes [ B.colXs6, CSS.axisLabelParam ]
    , Cp.nonSubmit
    ]
    [ HH.label [ HP.classes [ B.controlLabel ] ] [ HH.text "Is stacked" ]
    , HH.input
        [ HP.inputType HP.InputCheckbox
        , HP.checked state.isStacked
        , ARIA.label "Is stacked"
        , HE.onChecked $ HE.input_ (right ∘ Q.ToggleStacked)
        ]

    ]

renderIsSmooth ∷ ST.State → HTML
renderIsSmooth state =
  HH.form
    [ HP.classes [ B.colXs6, CSS.axisLabelParam ]
    , Cp.nonSubmit
    ]
    [ HH.label [ HP.classes [ B.controlLabel ] ] [ HH.text "Is stacked" ]
    , HH.input
        [ HP.inputType HP.InputCheckbox
        , HP.checked state.isStacked
        , ARIA.label "Is stacked"
        , HE.onChecked $ HE.input_ (right ∘ Q.ToggleSmooth)
        ]
    ]

eval ∷ Q.QueryC ~> DSL
eval = cardEval ⨁ areaBuilderEval

cardEval ∷ CC.CardEvalQuery ~> DSL
cardEval = case _ of
  CC.EvalCard info output next → do
    for_ (info.input ^? Lens._Just ∘ Port._ResourceAxes) \axes → do
      H.modify _{axes = axes}
      synchronizeChildren
    pure next
  CC.Activate next →
    pure next
  CC.Deactivate next →
    pure next
  CC.Save k → do
    st ← H.get
    r ← getAreaSelects
    let
      model =
        { dimension: _
        , value: _
        , valueAggregation: _
        , secondValue: r.secondValue >>= view _value
        , secondValueAggregation: r.secondValueAggregation >>= view _value
        , series: r.series >>= view _value
        , isStacked: st.isStacked
        , isSmooth: st.isSmooth
        , axisLabelAngle: st.axisLabelAngle
        , axisLabelFontSize: st.axisLabelFontSize
        }
        <$> (r.dimension >>= view _value)
        <*> (r.value >>= view _value)
        <*> (r.valueAggregation >>= view _value)
    pure $ k $ Card.BuildArea model
  CC.Load (Card.BuildArea (Just model)) next → do
    loadModel model
    H.modify _{ isStacked = model.isStacked
              , isSmooth = model.isSmooth
              , axisLabelAngle = model.axisLabelAngle
              , axisLabelFontSize = model.axisLabelFontSize
              }
    pure next
  CC.Load card next →
    pure next
  CC.SetDimensions dims next → do
    H.modify
      _{levelOfDetails =
           if dims.width < 576.0 ∨ dims.height < 416.0
             then Low
             else High
       }
    pure next
  CC.ModelUpdated _ next →
    pure next
  CC.ZoomIn next →
    pure next

areaBuilderEval ∷ Q.Query ~> DSL
areaBuilderEval = case _ of
  Q.SetAxisLabelAngle str next → do
    let fl = readFloat str
    unless (isNaN fl) do
      H.modify _{axisLabelAngle = fl}
      CC.raiseUpdatedP' CC.EvalModelUpdate
    pure next
  Q.SetAxisLabelFontSize str next → do
    let mbFS = Int.fromString str
    for_ mbFS \fs → do
      H.modify _{axisLabelFontSize = fs}
      CC.raiseUpdatedP' CC.EvalModelUpdate
    pure next
  Q.ToggleSmooth next → do
    H.modify \s → s{isSmooth = not s.isSmooth}
    CC.raiseUpdatedP' CC.EvalModelUpdate
    pure next
  Q.ToggleStacked next → do
    H.modify \s → s{isStacked = not s.isStacked}
    CC.raiseUpdatedP' CC.EvalModelUpdate
    pure next

peek ∷ ∀ a. CS.ChildQuery a → DSL Unit
peek _ = synchronizeChildren *> CC.raiseUpdatedP' CC.EvalModelUpdate

synchronizeChildren ∷ DSL Unit
synchronizeChildren = void do
  st ← H.get
  r ← getAreaSelects
  let
    newDimension =
      setPreviousValueFrom r.dimension
        $ autoSelect
        $ newSelect
        $ st.axes.category
        ⊕ st.axes.time
        ⊕ st.axes.value

    newValue =
      setPreviousValueFrom r.value
        $ autoSelect
        $ newSelect
        $ st.axes.value

    newValueAggregation =
      setPreviousValueFrom r.valueAggregation
        $ nonMaybeAggregationSelect

    newSecondValue =
      setPreviousValueFrom r.secondValue
        $ autoSelect
        $ newSelect
        $ ifSelected [ newValue ]
        $ st.axes.value
        ⊝ newValue

    newSecondValueAggregation =
      setPreviousValueFrom r.secondValueAggregation
        $ nonMaybeAggregationSelect

    newSeries =
      setPreviousValueFrom r.series
        $ autoSelect
        $ newSelect
        $ ifSelected [ newDimension ]
        $ st.axes.category
        ⊝ newDimension


  H.query' CS.cpValue unit $ right $ H.ChildF unit $ H.action $ S.SetSelect newValue
  H.query' CS.cpValue unit $ left $ H.action $ S.SetSelect newValueAggregation
  H.query' CS.cpSecondValue unit $ right $ H.ChildF unit $ H.action $ S.SetSelect newSecondValue
  H.query' CS.cpSecondValue unit $ left $ H.action $ S.SetSelect newSecondValueAggregation
  H.query' CS.cpSeries unit $ H.action $ S.SetSelect newSeries


loadModel ∷ M.AreaR → DSL Unit
loadModel r = void do
  H.query' CS.cpValue unit
    $ right
    $ H.ChildF unit
    $ H.action
    $ S.SetSelect
    $ fromSelected
    $ Just r.value

  H.query' CS.cpValue unit
    $ left
    $ H.action
    $ S.SetSelect
    $ fromSelected
    $ Just r.valueAggregation

  H.query' CS.cpDimension unit
    $ H.action
    $ S.SetSelect
    $ fromSelected
    $ Just r.dimension

  H.query' CS.cpSecondValue unit
    $ right
    $ H.ChildF unit
    $ H.action
    $ S.SetSelect
    $ fromSelected r.secondValue

  H.query' CS.cpSecondValue unit
    $ left
    $ H.action
    $ S.SetSelect
    $ fromSelected r.secondValueAggregation

  H.query' CS.cpSeries unit
    $ H.action
    $ S.SetSelect
    $ fromSelected r.series

type AreaSelects =
  { dimension ∷ Maybe (Select JCursor)
  , value ∷ Maybe (Select JCursor)
  , valueAggregation ∷ Maybe (Select Aggregation)
  , secondValue ∷ Maybe (Select JCursor)
  , secondValueAggregation ∷ Maybe (Select Aggregation)
  , series ∷ Maybe (Select JCursor)
  }

getAreaSelects ∷ DSL AreaSelects
getAreaSelects = do
  dimension ←
    H.query' CS.cpDimension unit $ H.request S.GetSelect
  value ←
    H.query' CS.cpValue unit $ right $ H.ChildF unit $ H.request S.GetSelect
  valueAggregation ←
    H.query' CS.cpValue unit $ left $ H.request S.GetSelect
  secondValue ←
    H.query' CS.cpSecondValue unit $ right $ H.ChildF unit $ H.request S.GetSelect
  secondValueAggregation ←
    H.query' CS.cpSecondValue unit $ left $ H.request S.GetSelect
  series ←
    H.query' CS.cpSeries unit $ H.request S.GetSelect
  pure { dimension
       , value
       , valueAggregation
       , secondValue
       , secondValueAggregation
       , series
       }
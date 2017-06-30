module SlamData.Workspace.Card.Setups.Viz.Component
  ( component
  ) where

import SlamData.Prelude

import CSS as CSS

import Data.Array as A
import Data.Lens ((^?))
import Data.Map as Map

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.CSS as HCSS
import Halogen.HTML.Properties as HP
import Halogen.Component.Proxy as HCP

import SlamData.Workspace.Card.CardType as CT
import SlamData.Workspace.Card.Component as CC
import SlamData.Workspace.Card.Eval.State as ES
import SlamData.Workspace.Card.Model as M
import SlamData.Workspace.Card.Setups.DimMap.Component as DM
import SlamData.Workspace.Card.Setups.DimMap.Component.State as DS
import SlamData.Workspace.Card.Setups.DimMap.Component.Query as DQ

import SlamData.Workspace.Card.Setups.Viz.Component.ChildSlot as CS
import SlamData.Workspace.Card.Setups.Viz.Component.Query as Q
import SlamData.Workspace.Card.Setups.Viz.Component.State as ST
import SlamData.Workspace.Card.Setups.Viz.VizTypePicker as VT
import SlamData.Workspace.Card.Setups.Viz.Auxiliary as Aux
import SlamData.Workspace.Card.CardType.VizType as VCT
import SlamData.Workspace.LevelOfDetails (LevelOfDetails(..))

type DSL = CC.InnerCardParentDSL ST.State Q.Query CS.ChildQuery CS.ChildSlot
type HTML = CC.InnerCardParentHTML Q.Query CS.ChildQuery CS.ChildSlot

component ∷ CC.CardOptions → CC.CardComponent
component =
  CC.makeCardComponent CT.SetupViz $ H.parentComponent
    { render
    , eval: cardEval ⨁ setupEval
    , receiver: const Nothing
    , initialState: const ST.initialState
    }

render ∷ ST.State → HTML
render state =
  HH.div
  [ HCSS.style $ CSS.width (CSS.pct 100.0) *> CSS.height (CSS.pct 100.0) ]
  $ ( if state.vizTypePickerExpanded
      then [ picker ]
      else [ button ] <> dims )
  ⊕ aux
  where
  button =
    HH.button
      [ HE.onClick $ HE.input_ $ right ∘ Q.ToggleVizPicker
      , HP.classes
          [ HH.ClassName "sd-viztype-button"
          ]
      ]
      [ HH.img
          [ HP.src $ VCT.darkIconSrc state.vizType ]
      , HH.p_ [ HH.text $ VCT.name state.vizType ]
      ]
  picker =
    HH.slot' CS.cpPicker unit VT.component unit
      $ HE.input \e → right ∘ Q.HandlePicker e
  dims = flip foldMap (Map.lookup state.vizType DS.packages) \package →
    [ HH.slot' CS.cpDims unit DM.component package
      $ HE.input \e → right ∘ Q.HandleDims e
    ]
  aux = foldMap A.singleton do
    auxState ← Map.lookup state.vizType state.auxes
    comp ← auxComponent
    pure
      $ HH.div_
      $ A.singleton
      $ HH.slot' CS.cpAux unit comp auxState
      $ HE.input \e → right ∘ Q.HandleAux e

  auxComponent = case state.vizType of
    VCT.Geo VCT.GeoHeatmap → pure $ HCP.proxy $ Aux.injAux Aux._geoHeatmap Aux.geoHeatmap
    VCT.Geo VCT.GeoMarker → pure $ HCP.proxy $ Aux.injAux Aux._geoMarker Aux.geoMarker
    VCT.Metric → pure $ HCP.proxy $ Aux.injAux Aux._metric Aux.metric
    VCT.Chart VCT.Area → pure $ HCP.proxy $ Aux.injAux Aux._area Aux.area
    VCT.Chart VCT.Bar → pure $ HCP.proxy $ Aux.injAux Aux._bar Aux.bar
    VCT.Chart VCT.Funnel → pure $ HCP.proxy $ Aux.injAux Aux._funnel Aux.funnel
    VCT.Chart VCT.Graph → pure $ HCP.proxy $ Aux.injAux Aux._graph Aux.graph
    VCT.Chart VCT.Heatmap → pure $ HCP.proxy $ Aux.injAux Aux._heatmap Aux.heatmap
    VCT.Chart VCT.Line → pure $ HCP.proxy $ Aux.injAux Aux._line Aux.line
    VCT.Chart VCT.PunchCard → pure $ HCP.proxy $ Aux.injAux Aux._punchCard Aux.punchCard
    VCT.Chart VCT.Scatter → pure $ HCP.proxy $ Aux.injAux Aux._scatter Aux.scatter
    _ → empty


cardEval ∷ CC.CardEvalQuery ~> DSL
cardEval = case _ of
  CC.Activate next →
    pure next
  CC.Deactivate next →
    pure next
  CC.Save k → do
    st ← H.get
    pure $ k $ M.SetupViz
      { dimMaps: st.dimMaps
      , vizType: st.vizType
      , auxes: st.auxes
      }
  CC.Load m next → do
    for_ (m ^? M._SetupViz) \r → do
      H.modify _
        { dimMaps = r.dimMaps
        , vizType = r.vizType
        }
      for_ (Map.lookup r.vizType r.dimMaps) \dimMap → do
        void $ H.query' CS.cpDims unit $ H.action $ DQ.Load dimMap
        H.raise CC.modelUpdate
    pure next
  CC.ReceiveInput _ _ next →
    pure next
  CC.ReceiveOutput _ _ next →
    pure next
  CC.ReceiveState evalState next → do
    for_ (evalState ^? ES._Axes) \axes → do
      H.modify _{ axes = Just axes }
      _ ← H.query' CS.cpPicker unit $ H.action $ VT.UpdateAxes axes
      _ ← H.query' CS.cpDims unit $ H.action $ DQ.SetAxes axes
      pure unit
    pure next
  CC.ReceiveDimensions _ reply →
    pure $ reply High

setupEval ∷ Q.Query ~> DSL
setupEval = case _ of
  Q.HandlePicker vt next → do
    H.modify _{ vizTypePickerExpanded = false }
    st ← H.get
    case vt of
      VT.SetVizType v → do
        for_ (Map.lookup v st.dimMaps) \dimMap →
          void $ H.query' CS.cpDims unit $ H.action $ DQ.Load dimMap

        H.modify _{ vizType = v }
        H.raise CC.modelUpdate
      _ → pure unit
    pure next
  Q.HandleDims msg next → do
    case msg of
      DQ.Update dimMap →
        H.modify \st → st{ dimMaps = Map.insert st.vizType dimMap st.dimMaps }
    H.raise CC.modelUpdate
    pure next
  Q.ToggleVizPicker next → do
    state ← H.get
    H.modify _{ vizTypePickerExpanded = true
              , vizType = VCT.PivotTable
              }
    for_ state.axes \axes →
      void $ H.query' CS.cpPicker unit $ H.action $ VT.UpdateAxes axes
    pure next
  Q.HandleAux auxState next → do
    H.modify \st → st { auxes = Map.insert st.vizType auxState st.auxes }
    H.raise CC.modelUpdate
    pure next
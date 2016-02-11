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

module SlamData.FileSystem.Breadcrumbs.Component where

import Prelude

import Data.Foldable (foldl)
import Data.Functor.Eff (liftEff)
import Data.List (List(..), reverse)
import Data.Maybe (maybe, Maybe(..))
import Data.Path.Pathy (rootDir, runDirName, dirName, parentDir)

import Halogen
import Halogen.HTML.Indexed as H
import Halogen.HTML.Properties.Indexed as P
import Halogen.Themes.Bootstrap3 as B

import SlamData.FileSystem.Effects (Slam())
import SlamData.FileSystem.Listing.Sort (Sort())
import SlamData.FileSystem.Routing (browseURL)
import SlamData.FileSystem.Routing.Salt (Salt())

import Utils.Path (DirPath())

import Quasar.Auth.Route as Ar

type State =
  { breadcrumbs :: List Breadcrumb
  , sort :: Sort
  , salt :: Salt
  , token :: Maybe String
  }

type Breadcrumb =
  { name :: String
  , link :: DirPath
  }

rootBreadcrumb :: Breadcrumb
rootBreadcrumb =
  { name: "Home"
  , link: rootDir
  }

mkBreadcrumbs :: DirPath -> Sort -> Salt -> State
mkBreadcrumbs path sort salt =
  { breadcrumbs: reverse $ go Nil path
  , sort: sort
  , salt: salt
  , token: Nothing
  }
  where
  go :: List Breadcrumb -> DirPath -> List Breadcrumb
  go result p =
    let result' = Cons { name: maybe "" runDirName (dirName p)
                       , link: p
                       } result
    in case parentDir p of
      Just dir -> go result' dir
      Nothing -> Cons rootBreadcrumb result

data Query a = Init a

comp :: Component State Query Slam
comp = component render eval

render :: State -> ComponentHTML Query
render r =
  H.ol
    [
      P.classes [ B.breadcrumb, B.colXs7 ]
    , P.initializer (\_ -> action Init)
    ]
  $ foldl (\views model -> view model <> views) [ ] r.breadcrumbs
  where
  view b =
    [ H.li_
        [ H.a
            [
              P.href $ href b
            ]
            [ H.text b.name ]
        ]
    ]
  href b =
    Ar.insertPermissionsToken r.token
    $ browseURL Nothing r.sort r.salt b.link


eval :: Eval Query State Query Slam
eval (Init next) = do
  mbToken <- liftEff $ Ar.permissionsToken
  modify (\s -> s{token = mbToken})
  pure next

{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedLists  #-}
{-# LANGUAGE TypeInType       #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | Helpers for defining filters manually.
module Servant.Util.Combinators.Filtering.Construction
    ( noFilters
    , mkFilteringSpec
    , (?/)
    , (?/=)
    , (?/>)
    , (?/~)
    ) where

import Universum hiding (filter)

import Data.Coerce (coerce)
import Data.Default (Default (..))
import GHC.TypeLits (ErrorMessage (..), KnownSymbol, TypeError)
import Servant (If)

import Servant.Util.Combinators.Filtering.Base
import Servant.Util.Combinators.Filtering.Filters
import Servant.Util.Combinators.Filtering.Support ()
import Servant.Util.Common

{- | Build a filtering specification.
Used along with "OverloadedLabels" extension and @($)@ / @($=)@ operators.

Example:

@
filteringSpec :: FilteringSpec ["id" ?: 'AutoFilter Int, "desc" ?: 'ManualFilter Text]
filteringSpec = mkFilteringSpec
    [ -- Constructing an auto filter
    , #id (FilterGT 0)

      -- The following three lines are equivalent
    , #id (FilterMatching 5)
    , #id $ FilterMatching 5
    , #id $= 5

      -- Constructing a manually implemented filter
    , #desc "You are my sunshine, my only sunshine"
    ]
@

You can freely use 'GHC.Exts.fromList' instead of this function.
-}
mkFilteringSpec :: [SomeFilter params] -> FilteringSpec params
mkFilteringSpec = FilteringSpec

-- | By default 'noFilters' is used.
instance Default (FilteringSpec params) where
    def = noFilters

-- | Return all items.
noFilters :: FilteringSpec params
noFilters = FilteringSpec []

type family IsSupportedFilter filter a :: Constraint where
    IsSupportedFilter filter a =
        If (Elem filter (SupportedFilters a))
          (() :: Constraint)
          (TypeError
              ( 'Text "Filter '" ':<>: 'ShowType filter ':<>:
                'Text "' is not supported for '" ':<>: 'ShowType a ':<>:
                'Text "' type"
              )
          )

-- | Safely construct 'TypeFilter'.
class MkTypeFilter filter fk a where
    mkTypeFilter :: filter -> TypeFilter fk a

instance ( filter ~ filterType a
         , IsAutoFilter filterType
         , IsSupportedFilter filterType a
         ) =>
         MkTypeFilter filter 'AutoFilter a where
    mkTypeFilter filter = TypeAutoFilter (SomeTypeAutoFilter filter)

instance (filter ~ a) => MkTypeFilter filter 'ManualFilter a where
    mkTypeFilter = TypeManualFilter

-- | Safely construct 'SomeFilter'.
class MkSomeFilter name filter (origParams :: [TyNamedFilter]) (params :: [TyNamedFilter]) where
    mkSomeFilter :: filter -> SomeFilter params

instance TypeError ('Text "Unknown filter " ':<>: 'ShowType name ':$$:
                    'Text "Allowed ones here: " ':<>: 'ShowType (TyNamedParamsNames origParams)) =>
         MkSomeFilter name filter origParams '[] where
    mkSomeFilter = error ":shrug:"

instance {-# OVERLAPPING #-}
         (MkTypeFilter filter fk a, KnownSymbol name, Typeable fk, Typeable a) =>
         MkSomeFilter name filter origParams ('TyNamedParam name (fk a) ': params) where
    mkSomeFilter filter =
        SomeFilter
        { sfName = symbolValT @name
        , sfFilter = mkTypeFilter @filter @fk @a filter
        }

instance MkSomeFilter name filter origParams params =>
         MkSomeFilter name filter origParams (param ': params) where
    mkSomeFilter filter = coerce $ mkSomeFilter @name @filter @origParams @params filter

-- | "Filter by" operation.
-- Wraps a filter corresponding to the given name into 'SomeFilter' which can later be
-- passed to 'mkSomeFilter'.
(?/)
    :: forall name params filter.
       MkSomeFilter name filter params params
    => NameLabel name -> filter -> SomeFilter params
(?/) _ = mkSomeFilter @name @_ @params
infixr 0 ?/

-- | "Filter by matching" operation.
(?/=)
    :: forall name params filter.
       MkSomeFilter name (FilterMatching filter) params params
    => NameLabel name -> filter -> SomeFilter params
(?/=) l = (l ?/) . FilterMatching
infixr 0 ?/=

-- | "Filter by 'is greater'" operation.
(?/>)
    :: forall name params filter.
       MkSomeFilter name (FilterComparing filter) params params
    => NameLabel name -> filter -> SomeFilter params
(?/>) l = (l ?/) . FilterGT
infixr 0 ?/>

-- | Construct a (manual) filter from a value with the same representation as expected one.
-- Helpful when newtypes are heavely used in API parameters.
(?/~)
    :: forall name filter' params filter.
       (MkSomeFilter name filter' params params, Coercible filter filter')
    => NameLabel name -> filter -> SomeFilter params
(?/~) l = (l ?/) . coerce @_ @filter'

_sample :: FilteringSpec ["id" ?: 'AutoFilter Int, "desc" ?: 'ManualFilter Text]
_sample =
    [ #id ?/ FilterMatching 5
    , #id ?/= 5
    , #desc ?/ "Kek"
    , #id ?/ FilterGT 3
    ]

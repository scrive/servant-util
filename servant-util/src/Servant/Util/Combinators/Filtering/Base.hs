{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE TypeInType    #-}

module Servant.Util.Combinators.Filtering.Base
    ( FilterKind (..)
    , TyNamedFilter
    , FilteringParams
    , SupportedFilters
    , FilteringSpec (..)
    , pattern DefFilteringCmd

    , SomeTypeAutoFilter (..)
    , TypeFilter (..)
    , SomeFilter (..)
    , extendSomeFilter
    , castTypeFilter

    , BuildableAutoFilter (..)
    , IsAutoFilter (..)
    , AreAutoFilters (..)
    , FilteringValueParser (..)
    , OpsDescriptions
    , parseFilteringValueAsIs
    , unsupportedFilteringValue
    , autoFiltersParsers

    , FilteringParamTypesOf
    , FilteringParamsOf
    , FilteringSpecOf

    , encodeQueryParamValue
    ) where

import Universum

import qualified Data.Map as M
import Data.Typeable (cast)
import Data.ByteString.Builder (toLazyByteString)
import qualified Data.ByteString.Lazy as BL
import Fmt (Buildable (..), Builder)
import GHC.Exts (IsList)
import Servant (FromHttpApiData (..), ToHttpApiData (..))
import Servant.API (NoContent)

import Servant.Util.Common

-- available from servant-client-core since
-- https://github.com/haskell-servant/servant/pull/1549
encodeQueryParamValue :: ToHttpApiData a => a  -> ByteString
encodeQueryParamValue = BL.toStrict . toLazyByteString . toEncodedUrlPiece

-- | We support two kinds of filters.
data FilterKind a
    = AutoFilter a
      -- ^ Automatic filter where different operations are supported (eq, in, cmp).
      -- When applied to backend, only filtered value should be supplied.
    | ManualFilter a
      -- ^ User-provided value is passed to backend implementation as-is,
      -- and filtering on this value should be written manually.

type TyNamedFilter = TyNamedParam (FilterKind Type)

-- | Servant API combinator which enables filtering on given fields.
--
-- If type @T@ appears with a name @name@ in @params@ argument, then query parameters of
-- @name[op]=value@ format will be accepted, where @op@ is a filtering operation
-- (e.g. equal, not equal, greater) and @value@ is an item of type @T@ we filter against.
-- Multiple filters will form a conjunction.
--
-- List of allowed filtering operations depends on type @T@ and is specified by
-- 'SupportedFilters' type family.
--
-- Operation argument is optional, when not specified "equality" filter is applied.
--
-- Endpoint implementation will receive 'FilteringSpec' value which contains information
-- about all filters passed by user. You can later put it to an appropriate function
-- to apply filtering.
data FilteringParams (params :: [TyNamedFilter])

-- | For a type of field, get a list of supported filtering operations on this field.
type family SupportedFilters ty :: [Type -> Type]

-- | If no filtering command specified, think like if the given one was passed.
pattern DefFilteringCmd :: Text
pattern DefFilteringCmd = "eq"

-- | Parses text on the right side of "=" sign in query parameters.
newtype FilteringValueParser a = FilteringValueParser (Text -> Either Text a)
    deriving (Functor)

-- | Delegate to 'FromHttpApiData'.
parseFilteringValueAsIs :: FromHttpApiData a => FilteringValueParser a
parseFilteringValueAsIs = FilteringValueParser parseUrlPiece

unsupportedFilteringValue :: Text -> FilteringValueParser a
unsupportedFilteringValue errMsg = FilteringValueParser (\_ -> Left errMsg)

-- | For each filtering operation specifies a short plain-english description.
-- This is not a 'Map' to prevent developer-defined entries order.
type OpsDescriptions = [(Text, Text)]

-- | How auto filters appear in logging.
class BuildableAutoFilter (filter :: Type -> Type) where
    buildAutoFilter
        :: Buildable a => Text -> filter a -> Builder

-- | Application of a filter type to Servant API.
class (Typeable filter, BuildableAutoFilter filter) =>
      IsAutoFilter (filter :: Type -> Type) where

    -- | For each supported filtering operation specifies a short plain-english
    -- description.
    autoFilterEnglishOpsNames
        :: OpsDescriptions

    -- | For each supported filtering operation specifies parser for a filtering value.
    autoFilterParsers
        :: FromHttpApiData a
        => Proxy filter -> Map Text (FilteringValueParser (filter a))

    -- | Encode a filter to query parameter value.
    autoFilterEncode
        :: ToHttpApiData a
        => filter a -> (Text, ByteString)

    mapAutoFilterValue
        :: (a -> b) -> filter a -> filter b
    default mapAutoFilterValue
        :: Functor filter => (a -> b) -> filter a -> filter b
    mapAutoFilterValue = fmap

-- | Multi-version of 'IsFilter'.
class AreAutoFilters (filters :: [Type -> Type]) where
    mapFilterTypes
        :: (forall filter. IsAutoFilter filter => Proxy filter -> a)
        -> Proxy filters -> [a]

instance AreAutoFilters '[] where
    mapFilterTypes _ _ = []

instance (IsAutoFilter filter, AreAutoFilters filters) =>
         AreAutoFilters (filter ': filters) where
    mapFilterTypes mapper _ =
        mapper (Proxy @filter) : mapFilterTypes mapper (Proxy @filters)

-- | Gather parsers from multiple filters.
autoFiltersParsers
    :: forall filters a.
       (AreAutoFilters filters, FromHttpApiData a)
    => Map Text $ FilteringValueParser (SomeTypeAutoFilter a)
autoFiltersParsers =
    let parsers = mapFilterTypes (fmap (fmap SomeTypeAutoFilter) . autoFilterParsers)
                                 (Proxy @filters)
    in foldl' (M.unionWithKey onDuplicateCmd) mempty parsers
  where
    onDuplicateCmd cmd = error $ "Different filters have the same command " <> show cmd

-- | Some filter for an item of type @a@.
-- Filter type is guaranteed to be one of @SupportedFilters a@.
data SomeTypeAutoFilter a =
    forall filter. IsAutoFilter filter => SomeTypeAutoFilter (filter a)

instance Functor SomeTypeAutoFilter where
    fmap f (SomeTypeAutoFilter filtr) = SomeTypeAutoFilter (mapAutoFilterValue f filtr)

instance Buildable a => Buildable (Text, SomeTypeAutoFilter a) where
    build (name, SomeTypeAutoFilter f) = buildAutoFilter name f

-- | Some filter for an item of type @a@.
data TypeFilter (fk :: Type -> FilterKind Type) a where
    -- | One of automatic filters for type @a@.
    -- Filter type is guaranteed to be one of @SupportedFilters a@.
    TypeAutoFilter
        :: SomeTypeAutoFilter a -> TypeFilter 'AutoFilter a

    -- | Manually implemented filter.
    TypeManualFilter
        :: a -> TypeFilter 'ManualFilter a

castTypeFilter
    :: forall fk1 a1 fk2 a2.
       (Typeable fk1, Typeable a1, Typeable fk2, Typeable a2)
    => TypeFilter fk1 a1 -> Maybe (TypeFilter fk2 a2)
castTypeFilter = cast

-- | Some filter.
-- This filter is guaranteed to match a type which is mentioned in @params@.
data SomeFilter (params :: [TyNamedFilter]) where
    SomeFilter :: (Typeable fk, Typeable a) =>
        { sfName :: Text
        , sfFilter :: TypeFilter fk a
        } -> SomeFilter params

extendSomeFilter :: SomeFilter params -> SomeFilter (param ': params)
extendSomeFilter (SomeFilter f n) = SomeFilter f n

-- | This is what you get in endpoint implementation, it contains all filters
-- supplied by a user.
-- Invariant: each filter correspond to some type mentioned in @params@.
newtype FilteringSpec (params :: [TyNamedFilter]) = FilteringSpec [SomeFilter params]
    deriving (IsList)

-- | For a given return type of an endpoint get corresponding filtering params.
-- This mapping is sensible, since we usually allow to filter only on fields appearing in
-- endpoint's response.
type family FilteringParamTypesOf a :: [TyNamedFilter]

-- | This you will most probably want to specify in API.
type FilteringParamsOf a = FilteringParams (FilteringParamTypesOf a)

-- | This you will most probably want to specify in an endpoint implementation.
type FilteringSpecOf a = FilteringSpec (FilteringParamTypesOf a)

type instance FilteringParamTypesOf NoContent = '[]

-- | This module provides "Network.Wai" middlware for exporting "Prometheus"
-- metrics and for instrumenting WAI applications.
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Wai.Middleware.Prometheus
  ( prometheus
  , PrometheusSettings(..)
  , Compression (..)
  , Default.def
  , instrumentHandlerValue
  , instrumentHandlerValueWithFilter
  , instrumentHandlerValueWithVersionLabel
  , ignoreRawResponses
  , instrumentApp
  , instrumentIO
  , observeSeconds
  , metricsApp
  , respondWithCompressedMetrics
  ) where

import qualified Data.Default as Default
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import qualified Network.Wai.Internal as Wai (Response(ResponseRaw))
import qualified Prometheus as Prom
import System.Clock (Clock(..), TimeSpec, diffTimeSpec, getTime, toNanoSecs)
import qualified Codec.Compression.GZip as GZip
import qualified Codec.Compression.Zstd as Zstd
import Data.String.Conversions (convertString)
import Data.Maybe


data Compression
 = Zstd Int
 | GZip Int

-- | Settings that control the behavior of the Prometheus middleware.
data PrometheusSettings = PrometheusSettings {
        prometheusEndPoint             :: [T.Text]
        -- ^ The path that will be used for exporting metrics. The default value
        -- is ["metrics"] which corresponds to the path /metrics.
    ,   prometheusInstrumentApp        :: Bool
        -- ^ Whether the default instrumentation should be applied to the
        -- application. If this is set to false the application can still be
        -- instrumented using the 'instrumentApp' function. The default value is
        -- True.
    ,   prometheusInstrumentPrometheus :: Bool
        -- ^ Whether the default instrumentation should be applied to the
        -- middleware that serves the metrics endpoint. The default value is
        -- True.
    ,   prometheusCompression          :: Maybe Compression
        -- ^ Which compression method to Use. The default value is Nothing.
    }

instance Default.Default PrometheusSettings where
    def = PrometheusSettings {
        prometheusEndPoint             = ["metrics"]
    ,   prometheusInstrumentApp        = True
    ,   prometheusInstrumentPrometheus = True
    ,   prometheusCompression          = Nothing
    }

{-# NOINLINE requestLatency #-}
requestLatency :: Prom.Vector Prom.Label3 Prom.Histogram
requestLatency = Prom.unsafeRegister $ Prom.vector ("handler", "method", "status_code") (Prom.histogram info Prom.defaultBuckets) Nothing
    where info = Prom.Info "http_request_duration_seconds"
                           "The HTTP request latencies in seconds."

{-# NOINLINE requestLatencyWithVersionLabel #-}
requestLatencyWithVersionLabel :: Prom.Vector Prom.Label4 Prom.Histogram
requestLatencyWithVersionLabel = Prom.unsafeRegister $ Prom.vector ("handler", "method", "status_code", "version") (Prom.histogram info Prom.defaultBuckets) Nothing
    where info = Prom.Info "http_request_duration_seconds"
                           "The HTTP request latencies in seconds."

-- | This function is used to populate the @handler@ label of all Prometheus metrics recorded by this library.
--
-- If you use this function you will likely want to override the default value
-- of 'prometheusInstrumentApp' to be false so that your app does not get double
-- instrumented.
--
-- WARNING: If you have 'ResponseRaw' values in your API, consider using
-- @instrumentHandlerValueWithFilter ignoreRawResponses@ instead.
instrumentHandlerValue ::
     (Wai.Request -> Text) -- ^ The function used to derive the "handler" value in Prometheus
  -> Wai.Application -- ^ The app to instrument
  -> Wai.Application -- ^ The instrumented app
instrumentHandlerValue = instrumentHandlerValueWithFilter Nothing Just

-- | This function is used to populate the @handler@ label of all Prometheus metrics recorded by this library.
--
-- If you use this function you will likely want to override the default value
-- of 'prometheusInstrumentApp' to be false so that your app does not get double
-- instrumented.
-- Added version label
--
-- WARNING: If you have 'ResponseRaw' values in your API, consider using
-- @instrumentHandlerValueWithFilter ignoreRawResponses@ instead.
instrumentHandlerValueWithVersionLabel ::
     Text -- ^ version label
  -> (Wai.Request -> Text) -- ^ The function used to derive the "handler" value in Prometheus
  -> Wai.Application -- ^ The app to instrument
  -> Wai.Application -- ^ The instrumented app
instrumentHandlerValueWithVersionLabel versionLabel = instrumentHandlerValueWithFilter (Just versionLabel) Just

-- | A more flexible variant of 'instrumentHandlerValue'.  The filter can change some
-- responses, or drop others entirely.
instrumentHandlerValueWithFilter ::
     Maybe Text -- ^ version label
  -> (Wai.Response -> Maybe Wai.Response) -- ^ Response filter
  -> (Wai.Request -> Text) -- ^ The function used to derive the "handler" value in Prometheus
  -> Wai.Application -- ^ The app to instrument
  -> Wai.Application -- ^ The instrumented app
instrumentHandlerValueWithFilter mbVersionLabel resFilter f app req respond = do
  start <- getTime Monotonic
  app req $ \res -> do
    case resFilter res of
      Nothing -> return ()
      Just res' -> do
        end <- getTime Monotonic
        let method = Just $ decodeUtf8 (Wai.requestMethod req)
        let status = Just $ T.pack (show (HTTP.statusCode (Wai.responseStatus res')))
        observeSeconds mbVersionLabel (f req) method status start end
    respond res

-- | 'Wai.ResponseRaw' values have two parts: an action that can be executed to construct a
-- 'Wai.Response', and a pure "backup" 'Wai.Response' in case the computation fails.  Since
-- the pure selectors like 'Wai.responseStatus' are pure and it makes no sense for them to
-- call the action, they just go to the backup response and pull the value from that:
--
-- @
-- responseStatus (ResponseRaw ...
--   (ResponseBuilder (Status 500 "blargh") ... ...))
-- == Status {statusCode = 500, statusMessage = "blargh"}
-- @
--
-- This is often not what you want.  For example, if you have an end-point for establishing
-- websocket connections that has a backup response with status 5xx, every websocket
-- connection request, whether successful or not, will register as an internal server error.
--
-- This helper therefore filters out all raw requests so they won't create any metrics.  Use
-- together with 'instrumentHandlerValueWithFilter'.
ignoreRawResponses :: Wai.Response -> Maybe Wai.Response
ignoreRawResponses (Wai.ResponseRaw {}) = Nothing
ignoreRawResponses res = Just res

-- | Instrument a WAI app with the default WAI metrics.
--
-- If you use this function you will likely want to override the default value
-- of 'prometheusInstrumentApp' to be false so that your app does not get double
-- instrumented.
instrumentApp ::
     Text -- ^ The label used to identify this app
  -> Wai.Application -- ^ The app to instrument
  -> Wai.Application -- ^ The instrumented app
instrumentApp handler app req respond =
  instrumentHandlerValue (const handler) app req respond

-- | Instrument an IO action with timing metrics. This function can be used if
-- you would like to get more fine grained metrics, for instance this can be
-- used to instrument individual end points.
--
-- If you use this function you will likely want to override the default value
-- of 'prometheusInstrumentApp' to be false so that your app does not get double
-- instrumented.
instrumentIO :: Text    -- ^ The label used to identify this IO operation
             -> IO a    -- ^ The IO action to instrument
             -> IO a    -- ^ The instrumented app
instrumentIO label io = do
    start  <- getTime Monotonic
    result <- io
    end    <- getTime Monotonic
    observeSeconds Nothing label Nothing Nothing start end
    return result

-- | Record an event to the middleware metric.
observeSeconds :: Maybe Text   -- ^ version label
               -> Text         -- ^ handler label
               -> Maybe Text   -- ^ method
               -> Maybe Text   -- ^ status
               -> TimeSpec     -- ^ start time
               -> TimeSpec     -- ^ end time
               -> IO ()
observeSeconds mbVersionLabel handler method status start end = do
    let latency :: Double
        latency = fromRational $ toRational (toNanoSecs (end `diffTimeSpec` start) % 1000000000)
    case mbVersionLabel of
      Nothing -> do
        Prom.withLabel requestLatency
                       (handler, fromMaybe "" method, fromMaybe "" status)
                       (flip Prom.observe latency)
      Just versionLabel -> do
        Prom.withLabel requestLatencyWithVersionLabel
                       (handler, fromMaybe "" method, fromMaybe "" status, versionLabel)
                       (flip Prom.observe latency)

-- | Expose Prometheus metrics and instrument an application with some basic
-- metrics (e.g. request latency).
prometheus :: PrometheusSettings -> Wai.Middleware
prometheus PrometheusSettings{..} app req respond =
    if     Wai.requestMethod req == HTTP.methodGet
        && Wai.pathInfo req == prometheusEndPoint
        -- XXX: Should probably be "metrics" rather than "prometheus", since
        -- "prometheus" can be confused with actual prometheus.
    then
      if prometheusInstrumentPrometheus
        then instrumentApp "prometheus" (const $ metricsResponse prometheusCompression) req respond
        else (metricsResponse prometheusCompression) respond
    else
      if prometheusInstrumentApp
        then instrumentApp "app" app req respond
        else app req respond

-- | WAI Application that serves the Prometheus metrics page regardless of
-- what the request is.
metricsApp :: Maybe Compression -> Wai.Application
metricsApp cmp = const (metricsResponse cmp)

metricsResponse :: Maybe Compression -> (Wai.Response -> IO Wai.ResponseReceived)
                -> IO Wai.ResponseReceived
metricsResponse compression = do
    if isJust compression
      then respondWithCompressedMetrics $ fromJust compression
      else respondWithMetrics

respondWithMetrics :: (Wai.Response -> IO Wai.ResponseReceived)
                   -> IO Wai.ResponseReceived
respondWithMetrics respond = do
    metrics <- Prom.exportMetricsAsText
    respond $ Wai.responseLBS HTTP.status200 headers metrics
    where
        headers = [(HTTP.hContentType, "text/plain; version=0.0.4")]

respondWithCompressedMetrics :: Compression -> (Wai.Response -> IO Wai.ResponseReceived)
                             -> IO Wai.ResponseReceived
respondWithCompressedMetrics compression respond = do
    metrics <- Prom.exportMetricsAsText
    let (contentTypeHeader, compressedRes) = compressAndGetHeader metrics
    respond $ Wai.responseLBS HTTP.status200 (getHeaders contentTypeHeader) compressedRes
    where
        getHeaders contentTypeHeader = [(HTTP.hContentType, "text/plain; version=0.0.4"), contentTypeHeader]
        compressAndGetHeader m = case compression of
                       Zstd n -> (,) (HTTP.hContentEncoding, "zstd") $ if n > 0 -- Throws error when compression level is 0.
                                    then convertString . Zstd.compress n . convertString $ m
                                    else m
                       GZip n -> (,) (HTTP.hContentEncoding, "gzip") $ GZip.compressWith (GZip.defaultCompressParams {GZip.compressLevel = GZip.CompressionLevel n}) m

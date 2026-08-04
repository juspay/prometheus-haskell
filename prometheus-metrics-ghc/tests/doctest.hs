module Main where

import Test.DocTest

main :: IO ()
main = doctest [
        -- Ignore any ~/.ghc/*/environments/* file; a stale one from another
        -- project points GHC at a package db that does not exist here.
        "-package-env=-"
    ,   "-isrc"
    ,   "Prometheus.Metric.GHC"
    ]

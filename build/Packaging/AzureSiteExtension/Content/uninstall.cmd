:: Copyright 2020 New Relic Corporation. All rights reserved.
:: SPDX-License-Identifier: Apache-2.0

SET NEW_RELIC_FOLDER="%WEBROOT_PATH%\newrelic"
IF EXIST %NEW_RELIC_FOLDER% (
  rd /S /q %NEW_RELIC_FOLDER%
)

SET NEW_RELIC_FOLDER="%WEBROOT_PATH%\newrelic_core"
IF EXIST %NEW_RELIC_FOLDER% (
  rd /S /q %NEW_RELIC_FOLDER%
)
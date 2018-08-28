#!/usr/bin/env bash

set -e
export CROMWELL_BUILD_REQUIRES_SECURE=true
# import in shellcheck / CI / IntelliJ compatible ways
# shellcheck source=/dev/null
source "${BASH_SOURCE%/*}/test.inc.sh" || source test.inc.sh

cromwell::build::setup_common_environment

cromwell::build::setup_centaur_environment

cromwell::build::assemble_jars


# Installing the AWS CLI
pip install awscli --upgrade --user
export AWS_SHARED_CREDENTIALS_FILE="${CROMWELL_BUILD_RESOURCES_DIRECTORY}"/aws_credentials
export AWS_CONFIG_FILE="${CROMWELL_BUILD_RESOURCES_DIRECTORY}"/aws_config

# pass integration directory to the inputs json otherwise remove it from the inputs file
INTEGRATION_TESTS=()
if [ "${CROMWELL_BUILD_IS_CRON}" = "true" ]; then
    INTEGRATION_TESTS=(-i "${CROMWELL_BUILD_CENTAUR_INTEGRATION_TESTS}")
    # Increase concurrent job limit to get tests to finish under three hours.
    # Increase read_lines limit because of read_lines call on hg38.even.handcurated.20k.intervals.
    CENTAUR_READ_LINES_LIMIT=512000
    export CENTAUR_READ_LINES_LIMIT
fi


# The following tests are skipped:
#
# TODO: Find tests to skip

centaur/test_cromwell.sh \
    -j "${CROMWELL_BUILD_JAR}" \
    -c "${CROMWELL_BUILD_RESOURCES_DIRECTORY}/aws_application.conf" \
    -n "${CROMWELL_BUILD_RESOURCES_DIRECTORY}/centaur_application.conf" \
    -g \
    -e localdockertest \
    "${INTEGRATION_TESTS[@]}"

cromwell::build::generate_code_coverage

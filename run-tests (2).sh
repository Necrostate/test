#!/bin/bash

# Exit on first error
set -e

readonly STARTTIME=$(date +%s)

readonly TEST_RUN=test_run
readonly TESTS_DIRECTORY=tests/*
readonly MODULE_SEARCH_PATH=.
readonly TEMPORARY_FOLDER="tmp"
readonly LOG_FILE_ENDING=".log"
readonly LOG_FILE="${0##*/}-${STARTTIME}${LOG_FILE_ENDING}"
readonly LOG_LEVEL_FAIL="fail"
readonly LOG_LEVEL_WARN="warn"
readonly LOG_LEVEL_INFO="info"
readonly LOG_LEVEL_DEBUG="debug"
readonly LOG_LEVEL_TRACE="trace"
readonly LOGS_FOLDER="logs"
readonly LOGS_ARCHIVE_FOLDER=${LOGS_FOLDER}/archive
readonly LANGUAGE_DE="de"
readonly LANGUAGE_EN="en"
readonly BROWSER_CHROME="chrome"
readonly BROWSER_FIREFOX="firefox"
readonly CLOUD_AWS="aws"
readonly CLOUD_AZURE="azure"
readonly REGION_EUROPE="euw"
readonly REGION_UNITED_STATES="usw2"
readonly STAGE_DEV="dev"
readonly STAGE_DINT="dint"
readonly STAGE_PRELIVE="prelive"
readonly OPTION_ALL="all"
readonly DEVSTACK_JIRA_URL=https://devstack.vwgroup.com/jira
readonly CURL_COMMAND="curl -sS"
readonly HTTP_OK=200
readonly WINDOW_WIDTH=1920
readonly WINDOW_HEIGHT=1200
readonly OUTPUT_DIRECTORY=reports

if [ ! -d "${LOGS_FOLDER}" ]; then
    mkdir ${LOGS_FOLDER}
fi

if [ ! -d "${LOGS_ARCHIVE_FOLDER}" ]; then
    mkdir -p ${LOGS_ARCHIVE_FOLDER}
fi

if [ ! -d "${TEMPORARY_FOLDER}" ]; then
    mkdir ${TEMPORARY_FOLDER}
fi

# copy old log files to archive folder
logFiles=(`find ${LOGS_FOLDER}/ -maxdepth 1 -name "*${LOG_FILE_ENDING}"`)
if [ ${#logFiles[@]} -gt 0 ]; then
    mv ${LOGS_FOLDER}/*${LOG_FILE_ENDING} ${LOGS_ARCHIVE_FOLDER}
fi

PATH_TO_LOG_FILE=${LOGS_FOLDER}/${LOG_FILE}

touch ${PATH_TO_LOG_FILE}

###### CONFIGURATION ######

if [ -f /.dockerenv ]; then
    echo "Script is called within docker."
else
    echo "Script is >not< called within docker."
    set -o allexport
    source "$HOME/.env-list-file"
    set +o allexport
fi

PATH=$PATH:$HOME/.gmdm/.webdrivers:$HOME/.gmdm/.jq:$HOME/.gmdm/.azcopy:$HOME/.gmdm/.adp-helper-cli
TEST_ENVIRONMENT_LANGUAGES=()
TEST_ENVIRONMENT_BROWSERS=()
OPTIONAL_PARAMETERS=()

HEADLESS_MODE=0
RUN_ALL_NOT_PASSED_TEST_CASES=0  # '0' if all test shall be executed, '1' if only failed test cases from given test execution shall be executed

STAGE=${STAGE_PRELIVE}
DISABLE_UPLOAD=0

# Define your test case (or many testcase by concatenating with "OR", e.g. GMDM-12345ORGMDM-54321)
LIST_OF_TESTS=GMDM-9786

# Maximum number of additional attempts to re-run failed tests 
# (script stops when all tests succeeded, or when this limit is reached)
RETRY_ON_FAILURE=0

# Number of parallely running tests 
# Note, not all tests can be executed parallel!
NUMBER_OF_TESTS_TO_EXECUTE_IN_PARALLEL=1

LANGUAGE=${LANGUAGE_EN}  # DE or EN or ALL
BROWSER=${BROWSER_CHROME}  # Chrome or Firefox or 'ALL'
CLOUD=${CLOUD_AZURE} # Aws or Azure
REGION=${REGION_EUROPE}  # euw or usw2

RESOURCE_DIRECTORY=resources
RESOURCES_OF_STAGE_AND_CLOUD_DIRECTORY=${RESOURCE_DIRECTORY}/test-environments/${CLOUD}/${STAGE}

LOG_LEVEL=${LOG_LEVEL_DEBUG} # 'FAIL', 'WARN', 'INFO', 'DEBUG', 'TRACE' 
RUN_TESTS_ON_THE_INTRANET=false # true or false
IGNORE_SSL=false # true or false (default: false)
CLEAR_OUTPUT_DIRECTORY=0
ZIP_TEST_RUNS=0
OPEN_ROBOT_LOG_HTML_FILE_AUTOMATICALLY=false

TEST_ENVIRONMENT_LANGUAGES+=(${LANGUAGE})
TEST_ENVIRONMENT_BROWSERS+=(${BROWSER})

LANGUAGE_PARAMETER_WAS_SET=false
BROWSER_PARAMETER_WAS_SET=false
STAGE_PARAMETER_WAS_SET=false
CLOUD_PARAMETER_WAS_SET=false
REGION_PARAMETER_WAS_SET=false

TEST_EXECUTION_IDS=()

TEST_SUITE_NAME=

DEVSTACK_USERNAME=
DEVSTACK_USER_API_TOKEN=

PASSED_ARGUMENTS=()

ARGUMENT_FILES_FOR_PABOT=

CUSTOMIZED_REPORT_FOLDER_ID=

ROBOT_FRAMEWORK_RETURN_CODE=

{


printArguments() {
    echo " Utility script was invoked with parameters: '${PASSED_ARGUMENTS[@]}'"
}

store_arguments() {
    local arg=$1
    local optarg=$2
    local optind=$3

    if [ ${arg} == "-" ]; then
        if [ ${optarg} == 'user-api-token' ]; then
            PASSED_ARGUMENTS+=(-$arg${optarg} "****")
        else
            if [ "${optind::1}" == "-" ]; then
                PASSED_ARGUMENTS+=(-$arg${optarg})
            else
                PASSED_ARGUMENTS+=(-$arg${optarg} ${optind})
            fi
        fi
    elif [ ${arg} == 'P' ]; then
        # Do not log password
        PASSED_ARGUMENTS+=(-$arg "****")
    else
        if [ "${optarg::1}" == "-" ]; then
            PASSED_ARGUMENTS+=(-$arg)
        else
            PASSED_ARGUMENTS+=(-$arg ${optarg})
        fi
    fi
}

printAsciiArtErrorAndExit() {
    local message=$1

    echo "--------------------------------------------------------------------------------------------------------";
    echo "*******************************";
    echo "*  ______                     *";
    echo "* |  ____|                    *";
    echo "* | |__   _ __ _ __ ___  _ __ *";
    echo "* |  __| | '__| '__/ _ \| '__|*";
    echo "* | |____| |  | | | (_) | |   *";
    echo "* |______|_|  |_|  \___/|_|   *";
    echo "*                             *";
    echo "*******************************";

    echo -e "\t ${message}"
    echo "--------------------------------------------------------------------------------------------------------";
    log_script_parameters
    exit 1
}

set_list_of_tests_to_all_from_test_execution()
{
    local testExecutionId=$1
    local runAllNotPassedTests=$2
    LIST_OF_TESTS=
    pageNumber=1
    listOfTests=NotEmpty
    additionalFilter="| select(.status==\"FAIL\" or .status==\"TODO\")"
    if [ ${runAllNotPassedTests} -eq 0 ]; then additionalFilter= ; fi
    while [ ! -z ${listOfTests} ];
    do
        listOfTests=$(${CURL_COMMAND}  -H "Content-Type: application/json" -X GET -u ${DEVSTACK_USERNAME}:${DEVSTACK_USER_API_TOKEN} ${DEVSTACK_JIRA_URL}/rest/raven/1.0/api/testexec/${testExecutionId}/test?page=${pageNumber} \
        | jq-win64.exe -r ".[] ${additionalFilter} .key" \
        | awk 'NR > 1 { printf(",") } {printf "%s",$0}')
        if [ ! -z ${listOfTests} ]; then
            separatorChar=
            if [ ${pageNumber} -eq 1 ]; then separatorChar= ; else separatorChar="," ; fi
            LIST_OF_TESTS=$LIST_OF_TESTS"${separatorChar}${listOfTests}"
        fi
        if [ ${runAllNotPassedTests} -ne 0 ]; then
            listOfAllTests=$(${CURL_COMMAND}  -H "Content-Type: application/json" -X GET -u ${DEVSTACK_USERNAME}:${DEVSTACK_USER_API_TOKEN} ${DEVSTACK_JIRA_URL}/rest/raven/1.0/api/testexec/${testExecutionId}/test?page=${pageNumber} \
            | jq-win64.exe -r ".[] .key" \
            | awk 'NR > 1 { printf(",") } {printf "%s",$0}')
            if [ ! -z ${listOfAllTests} ]; then
                listOfTests=NotEmpty
            fi
        fi
        pageNumber=$((pageNumber+1))
    done
}

## get all tests from specific XRay Test Execution
collect_tests()
{
    local testExecutionId=$1

    if [ -z ${DEVSTACK_USERNAME} ]; then
        printAsciiArtErrorAndExit "User name is empty. Please provide it when collecting tests from given test execution ID."
    elif [ -z ${DEVSTACK_USER_API_TOKEN} ]; then
        printAsciiArtErrorAndExit "User API tocken is empty. Please provide it when collecting tests from given test execution ID."
    elif [ -z ${testExecutionId} ]; then
        printAsciiArtErrorAndExit  "Test executions id is empty. Please provide it when collecting tests from given test execution ID."
    fi

    # Check whether credentials are correct 
    return_code=$(${CURL_COMMAND} -o /dev/null -w '%{response_code}' -H "Content-Type: application/json" -X GET -u ${DEVSTACK_USERNAME}:${DEVSTACK_USER_API_TOKEN} ${DEVSTACK_JIRA_URL}/rest/api/2/issue/${testExecutionId})
    if [ ${return_code} -ne ${HTTP_OK} ]; then
        printAsciiArtErrorAndExit "Failed to collect tests via 'HTTP-Request' from given test execution '${testExecutionId}' with return code: ${return_code}"
    fi

    local testPlanId=$(${CURL_COMMAND} -H "Content-Type: application/json" -X GET -u ${DEVSTACK_USERNAME}:${DEVSTACK_USER_API_TOKEN} ${DEVSTACK_JIRA_URL}/rest/api/2/issue/${testExecutionId}?fields=customfield_10251 \
    | jq-win64.exe -r ".fields | .customfield_10251 | .[]")


    if [ ${RUN_ALL_NOT_PASSED_TEST_CASES} -eq 0 ] || [ ${RUN_ALL_NOT_PASSED_TEST_CASES} -eq 1 ]; then
        set_list_of_tests_to_all_from_test_execution ${testExecutionId} ${RUN_ALL_NOT_PASSED_TEST_CASES}
    else
        printAsciiArtErrorAndExit "Parameter 'RUN_ALL_NOT_PASSED_TEST_CASES' has not supported value: '${RUN_ALL_NOT_PASSED_TEST_CASES}'"
    fi

    if [ -z ${LIST_OF_TESTS} ]; then
        printAsciiArtErrorAndExit "List of tests is empty. Maybe the script is configured wrongly! Stopping execution."
    fi

    local testEnvironmentLanguages=($(${CURL_COMMAND}  -H "Content-Type: application/json" -X GET -u ${DEVSTACK_USERNAME}:${DEVSTACK_USER_API_TOKEN} ${DEVSTACK_JIRA_URL}/rest/raven/1.0/api/testplan/${testPlanId}/testexecution \
    | jq-win64.exe -r ".[] | select(.key==\"${testExecutionId}\") | .testEnvironments" | egrep -iwo "${LANGUAGE_DE}|${LANGUAGE_EN}" \
    | awk 'NR > 1 { printf(" ") } {printf "%s",$0}'))

    if [ ${#testEnvironmentLanguages[@]} -ne 0 ]; then
        if [ "${LANGUAGE_PARAMETER_WAS_SET}" == "false" ]; then
            TEST_ENVIRONMENT_LANGUAGES=($(echo "${testEnvironmentLanguages[@]}" | awk '{print tolower($0)}'))
        else
            echo " Parameter for language was passed via command line, use this one: '${TEST_ENVIRONMENT_LANGUAGES[*]}'"
        fi
    else
        echo " Test execution has no language set. Use default one: '${TEST_ENVIRONMENT_LANGUAGES[*]}'"
    fi

    local testEnvironmentBrowsers=($(${CURL_COMMAND}  -H "Content-Type: application/json" -X GET -u ${DEVSTACK_USERNAME}:${DEVSTACK_USER_API_TOKEN} ${DEVSTACK_JIRA_URL}/rest/raven/1.0/api/testplan/${testPlanId}/testexecution \
    | jq-win64.exe -r ".[] | select(.key==\"${testExecutionId}\") | .testEnvironments" | egrep -iwo "${BROWSER_CHROME}|${BROWSER_FIREFOX}" \
    | awk 'NR > 1 { printf(" ") } {printf "%s",$0}'))

    if [ ${#testEnvironmentBrowsers[@]} -ne 0 ]; then
        if [ "${BROWSER_PARAMETER_WAS_SET}" == "false" ]; then
            TEST_ENVIRONMENT_BROWSERS=($(echo "${testEnvironmentBrowsers[@]}" | awk '{print tolower($0)}'))
        else
            echo " Parameter for browser was passed via command line, use this one: '${TEST_ENVIRONMENT_BROWSERS[*]}'"
        fi
    else
        echo " Test execution has no browser set. Use default one: '${TEST_ENVIRONMENT_BROWSERS[*]}'"
    fi

    local testEnvironmentStage=($(${CURL_COMMAND}  -H "Content-Type: application/json" -X GET -u ${DEVSTACK_USERNAME}:${DEVSTACK_USER_API_TOKEN} ${DEVSTACK_JIRA_URL}/rest/raven/1.0/api/testplan/${testPlanId}/testexecution \
    | jq-win64.exe -r ".[] | select(.key==\"${testExecutionId}\") | .testEnvironments" | egrep -iwo "${STAGE_DINT}|${STAGE_PRELIVE}|${STAGE_DEV}" \
    | awk 'NR > 1 { printf(" ") } {printf "%s",$0}'))

    if [ ${#testEnvironmentStage[@]} -ne 0 ]; then
        if [ "${STAGE_PARAMETER_WAS_SET}" == "false" ]; then
            STAGE=($(echo ${testEnvironmentStage} | awk '{print tolower($0)}'))
            RESOURCES_OF_STAGE_AND_CLOUD_DIRECTORY=${RESOURCE_DIRECTORY}/test-environments/${CLOUD}/${STAGE}
        else
            echo " Parameter for stage was passed via command line, use this one: '${STAGE}'"
        fi
    else
        echo " Test execution has no stage set. Use default one: '${STAGE}'"
    fi

    local testEnvironmentCloud=($(${CURL_COMMAND}  -H "Content-Type: application/json" -X GET -u ${DEVSTACK_USERNAME}:${DEVSTACK_USER_API_TOKEN} ${DEVSTACK_JIRA_URL}/rest/raven/1.0/api/testplan/${testPlanId}/testexecution \
    | jq-win64.exe -r ".[] | select(.key==\"${testExecutionId}\") | .testEnvironments" | egrep -iwo "${CLOUD_AWS}|${CLOUD_AZURE}" \
    | awk 'NR > 1 { printf(" ") } {printf "%s",$0}'))

    if [ ${#testEnvironmentCloud[@]} -ne 0 ]; then
        if [ "${CLOUD_PARAMETER_WAS_SET}" == "false" ]; then
            CLOUD=($(echo ${testEnvironmentCloud} | awk '{print tolower($0)}'))
            RESOURCES_OF_STAGE_AND_CLOUD_DIRECTORY=${RESOURCE_DIRECTORY}/test-environments/${CLOUD}/${STAGE}
        else
            echo " Parameter for cloud was passed via command line, use this one: '${CLOUD}'"
        fi
    else
        echo " Test execution has no cloud set. Use default one: '${CLOUD}'"
    fi

    local testEnvironmentRegion=($(${CURL_COMMAND}  -H "Content-Type: application/json" -X GET -u ${DEVSTACK_USERNAME}:${DEVSTACK_USER_API_TOKEN} ${DEVSTACK_JIRA_URL}/rest/raven/1.0/api/testplan/${testPlanId}/testexecution \
    | jq-win64.exe -r ".[] | select(.key==\"${testExecutionId}\") | .testEnvironments" | egrep -iwo "${REGION_EUROPE}|${REGION_UNITED_STATES}" \
    | awk 'NR > 1 { printf(" ") } {printf "%s",$0}'))

    if [ ${#testEnvironmentRegion[@]} -ne 0 ]; then
        if [ "${REGION_PARAMETER_WAS_SET}" == "false" ]; then
            REGION=($(echo ${testEnvironmentRegion} | awk '{print tolower($0)}'))
        else
            echo " Parameter for region was passed via command line, use this one: '${REGION}'"
        fi
    else
        echo " Test execution has no region set. Use default one: '${REGION}'"
    fi

    echo -e "\t The following tests from Test execution '${DEVSTACK_JIRA_URL}/browse/${testExecutionId}' are performed as follows..."
    echo -e "\t\t ... tests: ${LIST_OF_TESTS} ..."
    echo -e "\t\t ... languages='${TEST_ENVIRONMENT_LANGUAGES[*]}' ..."
    echo -e "\t\t ... browsers='${TEST_ENVIRONMENT_BROWSERS[*]}' ..."
    echo -e "\t\t ... stage='${STAGE}' ..."
    echo -e "\t\t ... cloud='${CLOUD}' ..."
    echo -e "\t\t ... region='${REGION}' ..."
}

upload_log_file_to_jira_issue()
{
    if [ ${#TEST_EXECUTION_IDS[@]} -ne 0 ]; then
        echo "> Uploading log files to follwing test executions: ${TEST_EXECUTION_IDS[*]}"
        for testExecutionId in "${TEST_EXECUTION_IDS[@]}"
        do
            upload_attachment_to_jira_issue ${testExecutionId} ${PATH_TO_LOG_FILE}
        done
    fi
}

upload_attachment_to_jira_issue()
{
    if [ ${DISABLE_UPLOAD} -eq 0 ]; then
        local testExecutionId=$1

        if [ ! -z ${testExecutionId} ]; then
            local path_to_attachment=$2
            echo "> Attach file '${path_to_attachment}' to '${testExecutionId}'"
            ${CURL_COMMAND} -D- -u ${DEVSTACK_USERNAME}:${DEVSTACK_USER_API_TOKEN} -X POST -H "X-Atlassian-Token: nocheck" -F "file=@${path_to_attachment}" ${DEVSTACK_JIRA_URL}/rest/api/2/issue/${testExecutionId}/attachments > /dev/null
        fi
    else 
        echo "> Upload is disabled."
    fi
}

upload_results_to_xray()
{   
    if [ ${DISABLE_UPLOAD} -eq 0 ]; then
        local pathToOutputFile=$1
        local pathToArchive=$2
        local testExecutionId=$3
        echo "> Import test results to '${testExecutionId}'"
        ${CURL_COMMAND} -H "Content-Type: multipart/form-data" -u ${DEVSTACK_USERNAME}:${DEVSTACK_USER_API_TOKEN} -F "file=@${pathToOutputFile}" ${DEVSTACK_JIRA_URL}/rest/raven/1.0/import/execution/robot?testExecKey=${testExecutionId} > /dev/null
        archiveSize="$(wc -c ${pathToArchive} | awk '{print $1}')"
        # [Andreas Kruschwitz, 25.11.2022] Jira on devstack has maximum size limit of 50MB for attachments
        maximumSizeLimitJiraAttachments=52428800
        if [ ${archiveSize} -gt ${maximumSizeLimitJiraAttachments} ]; then
            commonPartName=${pathToArchive}-part
            split -b ${maximumSizeLimitJiraAttachments} "${pathToArchive}" ${commonPartName}
            allArchiveParts="$( ls ${commonPartName}* )"
            for part in ${allArchiveParts}
            do
                upload_attachment_to_jira_issue ${testExecutionId} ${part}
            done
        else
            upload_attachment_to_jira_issue ${testExecutionId} ${pathToArchive}
        fi
    else 
        echo "> Upload is disabled."
    fi
}

check_configuration() {
    case ${LANGUAGE} in
        ${LANGUAGE_EN})
        ;;
        ${LANGUAGE_DE})
        ;;
        ${OPTION_ALL})
        ;;
        *)
        printAsciiArtErrorAndExit "LANGUAGE is configured wrongly: ${LANGUAGE}"
        ;;
    esac

    case ${BROWSER} in
        ${BROWSER_CHROME})
        ;;
        ${BROWSER_FIREFOX})
        ;;
        ${OPTION_ALL})
        ;;
        *)
        printAsciiArtErrorAndExit "Browser is configured wrongly: ${BROWSER}"
        ;;
    esac

    case ${CLOUD} in
        ${CLOUD_AWS})
        ;;
        ${CLOUD_AZURE})
        ;;
        *)
        printAsciiArtErrorAndExit "Cloud is configured wrongly: ${CLOUD}"
        ;;
    esac

    case ${REGION} in
        ${REGION_EUROPE})
        ;;
        ${REGION_UNITED_STATES})
        ;;
        *)
        printAsciiArtErrorAndExit "Region is configured wrongly: ${REGION}"
        ;;
    esac

    case ${STAGE} in
        ${STAGE_DINT})
        ;;
        ${STAGE_PRELIVE})
        ;;
        ${STAGE_DEV})
        ;;
        *)
        printAsciiArtErrorAndExit "Stage is configured wrongly: ${STAGE}"
        ;;
    esac

    case ${LOG_LEVEL} in
        ${LOG_LEVEL_FAIL})
        ;;
        ${LOG_LEVEL_WARN})
        ;;
        ${LOG_LEVEL_INFO})
        ;;
        ${LOG_LEVEL_DEBUG})
        ;;
        ${LOG_LEVEL_TRACE})
        ;;
        *)
        printAsciiArtErrorAndExit "Log level is configured wrongly: ${LOG_LEVEL}"
        ;;
    esac

    if  [ -z ${TEST_SUITE_NAME} ] && [ -z ${LIST_OF_TESTS} ]; then
        printAsciiArtErrorAndExit "Test suite name (${TEST_SUITE_NAME}) and list of tests (${LIST_OF_TESTS}) are both empty. Not tests are executed."
    fi
}

transform_to_multi_character_parameter()
{
    # [Andreas Kruschwitz, 02.02.2022] ATTENTION: Do not add any echo command within this function.
    # Otherwise the return value is not returned correctly
    local argument=$1
    local multiparameter=

    case ${argument} in
            a) # Use another id (e.g. Azure Pipeline build id) instead of timestamp for unique report folder id
                multiparameter=report-folder-id
            ;;
            b) # Execute tests with browser 'firefox' or 'chrome', or 'ALL' 
               multiparameter=browser
            ;;
            C) # Execute tests in cloud 'aws' or 'azure'
                multiparameter=cloud
            ;;
            c) # Clear output and temp directory before executing tests
                multiparameter=clean
            ;;
            d) # Check syntax for test data
                multiparameter=check-syntax
            ;;
            D) # Disable upload of test results
                multiparameter=disable-upload
            ;;
            e) # Execute tests in region 'euw' or 'usw2'
                multiparameter=region
            ;;
            f) # Run only test cases that are not 'PASSED' until now ('FAILED' OR 'TODO') from given test execution
                multiparameter=run-open-tests
            ;;
            h) # Execute ui tests in headless mode
                multiparameter=headless-mode
            ;;
            i) # Execute tests on intranet
                multiparameter=intranet
            ;;
            L) # Set log level to 'FAIL', 'WARN', 'INFO', 'DEBUG', 'TRACE' 
                multiparameter=log-level
            ;;
            l) # Execute tests in language 'DE', 'EN', or 'ALL' 
                multiparameter=language
            ;;
            r) # Maximum number of additional attempts to re-run failed tests 
                multiparameter=retry-on-failure
            ;;
            R) # Automatically open Robot Framework log file after test were executed
                multiparameter=log-file
            ;;
            s) # Set test suite name which test cases shall be executed
                multiparameter=test-suite-name
            ;;
            S) # Execute tests on STAGE 'prelive', 'dint' or 'dev'
                multiparameter=stage
            ;;
            t) # Set list of tests that shall be executed (e.g. GMDM-12345,GMDM-54321)
                multiparameter=tests
            ;;
            T) # Set test execution to run
                multiparameter=test-execution
            ;;
            u) # Display help.
                multiparameter=help
            ;;
            U) # Set devstack username
                multiparameter=user-name
            ;;
            p) # Number of tests executed in parallel
                multiparameter=parallel-tests
            ;;
            P) # Set devstack username api token
                multiparameter=user-api-token
            ;;
            x) # Stop test execution on first error
                multiparameter=exit-on-failure
            ;;
            z) # Zip test runs at the end
                multiparameter=zip-results
            ;;
            ?)
                printAsciiArtErrorAndExit "Unsupported single-character parameter: ${argument}"
            ;;
    esac
    echo "${multiparameter}"
}

read_configuration()
{
    usage() { echo "$0 usage:" && grep " *)\ #" $0; }
    [ $# -eq 0 ] && usage

    echo "###########################################################################################################################"
    echo "   _____             __ _                       _   _             "
    echo "  / ____|           / _(_)                     | | (_)            "
    echo " | |     ___  _ __ | |_ _  __ _ _   _ _ __ __ _| |_ _  ___  _ __  "
    echo " | |    / _ \| '_ \|  _| |/ _\` | | | | '__/ _\` | __| |/ _ \| '_\ "
    echo " | |___| (_) | | | | | | | (_| | |_| | | | (_| | |_| | (_) | | | |"
    echo "  \_____\___/|_| |_|_| |_|\__, |\__,_|_|  \__,_|\__|_|\___/|_| |_|"
    echo "                           __/ |                                  "
    echo "                          |___/                                   "

    while getopts "a:b:cC:dDe:fhil:L:n:r:Rs:S:t:T:uU:P:p:xz-:" arg; do
        store_arguments ${arg} ${OPTARG// /} ${!OPTIND}
        
        local currentMultiParameter=
        local value=
        local shiftParameter=0

        if [ ${arg} == "-" ]; then
            if [[ ${OPTARG} =~ "=" ]]; then
                value=${OPTARG#*=}
                currentMultiParameter=${OPTARG%=${value}}
            else
                currentMultiParameter=${OPTARG}
                value=${!OPTIND}
            fi
            shiftParameter=1
        else
            currentMultiParameter=$(transform_to_multi_character_parameter ${arg})
            value=${OPTARG}
        fi

        if [ ${currentMultiParameter} != 'user-api-token' ]; then
            value=$(echo ${value} | awk '{print tolower($0)}')
        fi

        case ${currentMultiParameter} in
            report-folder-id) # Use another id (e.g. Azure Pipeline build id) instead of timestamp for unique report folder id
                CUSTOMIZED_REPORT_FOLDER_ID=${value}
                echo -e "\t Customized id '${CUSTOMIZED_REPORT_FOLDER_ID}' is used for unique report folder id"
               ;;
            argument-files-for-pabot) # To pass a list of argument files to pabot, e.g. '--argumentfile0 argumentfile0.txt --argumentfile1 argumentfile1.txt'
                ARGUMENT_FILES_FOR_PABOT=$(cat "${value}")
                echo -e "\t Argument files passed to pabot are ='${ARGUMENT_FILES_FOR_PABOT}'"
                ;;
            cloud) # Execute tests in cloud 'aws' or 'azure'
                CLOUD=${value}
                RESOURCES_OF_STAGE_AND_CLOUD_DIRECTORY=${RESOURCE_DIRECTORY}/test-environments/${CLOUD}/${STAGE}
                CLOUD_PARAMETER_WAS_SET=true
                echo -e "\t Tests are executed on cloud='${CLOUD}'"
                ;;
            clean) # Clear output and temp directory before executing tests
                CLEAR_OUTPUT_DIRECTORY=1
                echo -e "\t Output directory ${OUTPUT_DIRECTORY} and temp directoy ${TEMPORARY_FOLDER} will be cleared before tests are executed"
                shiftParameter=0
                ;;
            check-syntax) # Check syntax for test data
                OPTIONAL_PARAMETERS+=("--dryrun")
                echo -e "\t Just checking syntax of test cases."
                shiftParameter=0
                ;;
            disable-upload) # Disable upload of test results
                DISABLE_UPLOAD=1
                echo -e "\t Disable upload to jira."
                shiftParameter=0
                ;;
            log-level) # Set log level to 'FAIL', 'WARN', 'INFO', 'DEBUG', 'TRACE' 
                LOG_LEVEL=${value}
                echo -e "\t Tests are executed with log level: ${LOG_LEVEL}"
                ;;
            log-file) # Automatically open Robot Framework log file after test were executed
                OPEN_ROBOT_LOG_HTML_FILE_AUTOMATICALLY=true
                echo -e "\t Robot Framework log.html file is opened automatically at the end."
                shiftParameter=0
                ;;
            parallel-tests) # Number of tests executed in parallel
                NUMBER_OF_TESTS_TO_EXECUTE_IN_PARALLEL=${value}
                echo -e "\t Tests are executed in parallel: ${NUMBER_OF_TESTS_TO_EXECUTE_IN_PARALLEL} tests in parallel"
                ;;
            region) # Execute tests in region 'euw' or 'usw2'
                REGION=${value}
                REGION_PARAMETER_WAS_SET=true
                echo -e "\t Tests are executed on region='${REGION}'"
                ;;
            stage) # Execute tests on STAGE 'prelive', 'dint' or 'dev'
                STAGE=${value}
                RESOURCES_OF_STAGE_AND_CLOUD_DIRECTORY=${RESOURCE_DIRECTORY}/test-environments/${CLOUD}/${STAGE}
                STAGE_PARAMETER_WAS_SET=true
                echo -e "\t Tests are executed on stage='${STAGE}'"
                ;;
            test-execution) # Set test execution to run
                TEST_EXECUTION_IDS+=(`echo "${value}" | sed 's/,/\n/g' | awk '{print toupper($0)}'`)
                TEST_SUITE_NAME=
                echo -e "\t Run all tests from test execution '${TEST_EXECUTION_IDS[*]}'."
                ;;
            user-name) # Set devstack username
                DEVSTACK_USERNAME=${value}
                echo -e "\t Tests are executed with user: ${DEVSTACK_USERNAME}"
                ;;
            user-api-token) # Set devstack username api token
                DEVSTACK_USER_API_TOKEN=${value}
                echo -e "\t Setting user api token."
                ;;
            help) # Display help.
                usage
                shiftParameter=0
                exit 0
                ;;
            browser) # Execute tests with browser 'firefox' or 'chrome', or 'ALL' 
                BROWSER=${value}
                unset TEST_ENVIRONMENT_BROWSERS
                if [ ${BROWSER} == ${OPTION_ALL} ]; then
                    TEST_ENVIRONMENT_BROWSERS=(${BROWSER_CHROME} ${BROWSER_FIREFOX})
                else
                    TEST_ENVIRONMENT_BROWSERS=(${BROWSER})
                fi
                BROWSER_PARAMETER_WAS_SET=true
                echo -e "\t Tests are executed with browser='${TEST_ENVIRONMENT_BROWSERS[*]}'"
            ;;
            run-open-tests) # Run only test cases that are not 'PASSED' until now ('FAILED' OR 'TODO') from given test execution
                RUN_ALL_NOT_PASSED_TEST_CASES=1
                echo -e "\t Run only test cases that are not 'PASSED' from given test execution."
                shiftParameter=0
            ;;
            headless-mode) # Execute ui tests in headless mode
                HEADLESS_MODE=1
                echo -e "\t Tests are executed in headless mode."
                shiftParameter=0
            ;;
            intranet) # Execute tests on intranet
                RUN_TESTS_ON_THE_INTRANET=true
                IGNORE_SSL=true
                echo -e "\t Tests are executed on intranet."
                PATH=$PATH:$HOME/AppData/Local/Mozilla\ Firefox
                shiftParameter=0
            ;;
            language) # Execute tests in language 'DE', 'EN', or 'ALL' 
                LANGUAGE="${value}"
                unset TEST_ENVIRONMENT_LANGUAGES
                if [ ${LANGUAGE} == ${OPTION_ALL} ]; then
                    TEST_ENVIRONMENT_LANGUAGES=(${LANGUAGE_DE} ${LANGUAGE_EN})
                else
                    TEST_ENVIRONMENT_LANGUAGES=(${LANGUAGE})
                fi
                LANGUAGE_PARAMETER_WAS_SET=true
                echo -e "\t Tests are executed in language='${TEST_ENVIRONMENT_LANGUAGES[*]}'"
            ;;
            retry-on-failure) # Maximum number of additional attempts to re-run failed tests 
                RETRY_ON_FAILURE=${value}
                echo -e "\t Failed tests are executed a maximum of '${RETRY_ON_FAILURE} times'."
            ;;
            test-suite-name) # Set test suite name which test cases shall be executed
                TEST_SUITE_NAME=${value}
                LIST_OF_TESTS=
                echo -e "\t All test cases belonging to test suite '${TEST_SUITE_NAME} will be executed'."
            ;;
            tests) # Set list of tests that shall be executed (e.g. GMDM-12345,GMDM-54321)
                local capitalLetters=$(echo ${value} | awk '{print toupper($0)}')
                LIST_OF_TESTS=${capitalLetters// /} # here we remove all empty spaces within comma separated list
                local parameter=${capitalLetters}
                while [ ${parameter: -1} == "," ]; do
                    local nextParameter=$(echo ${!OPTIND} | awk '{print toupper($0)}')
                    if [ ${nextParameter::1} == "G" ]; then
                        LIST_OF_TESTS+=${nextParameter}
                        PASSED_ARGUMENTS+=(${nextParameter})
                        OPTIND=$(( $OPTIND + 1 ))
                    fi
                    parameter=${nextParameter}
                done
                TEST_SUITE_NAME=
                echo -e "\t Run following tests: ${LIST_OF_TESTS}"
            ;;
            exit-on-failure) # Stop test execution on first error
                OPTIONAL_PARAMETERS+=("--exitonfailure")            
                echo -e "\t Test run stops after first test case failed."
                shiftParameter=0
            ;;
            zip-results) # Zip test runs at the end
                ZIP_TEST_RUNS=1
                echo -e "\t Test runs are zipped after execution."
                shiftParameter=0
            ;;
            *)
                printAsciiArtErrorAndExit "Unsupported multi-character parameter: ${currentMultiParameter}"
                shiftParameter=0
                ;;
        esac
        if [ $shiftParameter -eq 1 ]; then OPTIND=$(( $OPTIND + 1 )); fi
    done

    echo "###########################################################################################################################"
}

prepare_test_execution()
{
    local testExecutionId=$1
    echo ""
    echo "###########################################################################################################################"
    echo "  _____                                _   _             ";
    echo " |  __ \                              | | (_)            ";
    echo " | |__) | __ ___ _ __   __ _ _ __ __ _| |_ _  ___  _ __  ";
    echo " |  ___/ '__/ _ \ '_ \ / _\` | '__/ _\` | __| |/ _ \| '_ \ ";
    echo " | |   | | |  __/ |_) | (_| | | | (_| | |_| | (_) | | | |";
    echo " |_|   |_|  \___| .__/ \__,_|_|  \__,_|\__|_|\___/|_| |_|";
    echo "                | |                                      ";
    echo "                |_|                                      ";


    if [ ! -z ${testExecutionId} ]; then
        collect_tests ${testExecutionId}
    fi

    # Decide whether to use basic robot or pabot for parallel execution
    COMMAND=(robot)
    if  [ ${NUMBER_OF_TESTS_TO_EXECUTE_IN_PARALLEL} -gt 1 ]; then
        COMMAND=(pabot --verbose --pabotlib --testlevelsplit --processes ${NUMBER_OF_TESTS_TO_EXECUTE_IN_PARALLEL} ${ARGUMENT_FILES_FOR_PABOT})
    fi

    COMMAND_ENVIRONMENT_VARIABLES=(env REGION=${REGION} REGION_EUROPE=${REGION_EUROPE} REGION_UNITED_STATES=${REGION_UNITED_STATES} CLOUD_AWS=${CLOUD_AWS} CLOUD_AZURE=${CLOUD_AZURE} CLOUD=${CLOUD} IGNORE_SSL=${IGNORE_SSL} INTRANET_MODE=${RUN_TESTS_ON_THE_INTRANET} STAGE=${STAGE} OPEN_ROBOT_LOG_HTML_FILE_AUTOMATICALLY=${OPEN_ROBOT_LOG_HTML_FILE_AUTOMATICALLY})

    if [ ${HEADLESS_MODE} -eq 1 ]; then
        COMMAND_ENVIRONMENT_VARIABLES+=(MOZ_HEADLESS=${HEADLESS_MODE} MOZ_HEADLESS_HEIGHT=${WINDOW_HEIGHT} MOZ_HEADLESS_WIDTH=${WINDOW_WIDTH})
    fi

    ROBOT_COMMON_ARGUMENTS=(
        --name Tqa-Test-Automation
        --listener libraries/Listener.py ${OPTIONAL_PARAMETERS}
        --loglevel ${LOG_LEVEL} 
        --variable HEADLESS_MODE:${HEADLESS_MODE} 
        --variable WINDOW_WIDTH:${WINDOW_WIDTH} 
        --variable WINDOW_HEIGHT:${WINDOW_HEIGHT} 
        --variable TEMPORARY_FOLDER:${TEMPORARY_FOLDER} 
        --variable cloud:${CLOUD}
        --variablefile $RESOURCE_DIRECTORY/test-environments/${CLOUD}/users.yaml 
        --variablefile $RESOURCES_OF_STAGE_AND_CLOUD_DIRECTORY/${REGION}/endpoints.yaml
        --variablefile $RESOURCES_OF_STAGE_AND_CLOUD_DIRECTORY/cloud-config.yaml 
        --variablefile $RESOURCES_OF_STAGE_AND_CLOUD_DIRECTORY/${REGION}/permanent-testdata.yaml
        --pythonpath ${MODULE_SEARCH_PATH} ${TESTS_DIRECTORY}
    )

    # Bring multiple tests into Robot-style
    LIST_OF_TESTS_IN_ROBOT_STYLE=($(echo "${LIST_OF_TESTS}" | awk '{print tolower($0)}'))
    LIST_OF_TESTS_IN_ROBOT_STYLE=`echo "${LIST_OF_TESTS_IN_ROBOT_STYLE[@]}" | sed -r 's/\s*,\s*/OR/g'`


    # Do NOT exit on first error since we want to retry failed tests 
    set +e
    echo "###########################################################################################################################"
}

execute_tests() {

    echo ""
    echo "###########################################################################################################################"
    echo "  ______                     _   _             ";
    echo " |  ____|                   | | (_)            ";
    echo " | |__  __  _____  ___ _   _| |_ _  ___  _ __  ";
    echo " |  __| \ \/ / _ \/ __| | | | __| |/ _ \| '_ \ ";
    echo " | |____ >  <  __/ (__| |_| | |_| | (_) | | | |";
    echo " |______/_/\_\___|\___|\__,_|\__|_|\___/|_| |_|";
    echo "                                               ";
    echo "                                               ";

    local language=$1
    local browser=$2
    local testExecutionId=$3
    
    # Run the first test run
    CURRENT_TEST_RUN_NUMBER=0
    REPORT_FOLDER_ID=
    if [ ! -z ${CUSTOMIZED_REPORT_FOLDER_ID} ]; then
        REPORT_FOLDER_ID=${CUSTOMIZED_REPORT_FOLDER_ID}
    else
        REPORT_FOLDER_ID=`date +%Y-%m-%d_%H-%M-%S`
    fi
    CURRENT_TEST_EXECUTION_OUTPUT_FOLDER=${OUTPUT_DIRECTORY}/${REPORT_FOLDER_ID}_${language}_${browser}_${STAGE}
    CURRENT_TEST_RUN_OUTPUT_FOLDER=${CURRENT_TEST_EXECUTION_OUTPUT_FOLDER}/${TEST_RUN}_${CURRENT_TEST_RUN_NUMBER}
    SCREENSHOT_SUB_DIRECTORY=screenshots_${TEST_RUN}_${CURRENT_TEST_RUN_NUMBER}
    SCREENSHOT_DIRECTORY=${CURRENT_TEST_RUN_OUTPUT_FOLDER}/${SCREENSHOT_SUB_DIRECTORY}
    ROBOT_TESTS_TO_EXECUTE_ARGUMENT=()


    # [Andreas Kruschwitz, 14.10.2022] Exclude those tests which must be executed on another cloud
    excludedCloudTests=
    if [ "$CLOUD" = "${CLOUD_AWS}" ]; then excludedCloudTests=${CLOUD_AZURE}; else excludedCloudTests=${CLOUD_AWS}; fi
    if [ ! -z ${LIST_OF_TESTS} ]; then
        ROBOT_TESTS_TO_EXECUTE_ARGUMENT=(--include ${LIST_OF_TESTS_IN_ROBOT_STYLE} --exclude=${excludedCloudTests})
    else
        ROBOT_TESTS_TO_EXECUTE_ARGUMENT=(--suite ${TEST_SUITE_NAME} --exclude=${excludedCloudTests})
    fi
    
    echo "> Running tests on stage '${STAGE}' with language '${language}' and browser '${browser}'."
    echo "> Output is stored at ${CURRENT_TEST_EXECUTION_OUTPUT_FOLDER}."

    mkdir -p ${CURRENT_TEST_RUN_OUTPUT_FOLDER}
    TEST_RUN_RESULT_FILES=${CURRENT_TEST_RUN_OUTPUT_FOLDER}/output.xml

    logTitle="Log file for tests executed on stage '${STAGE}' with language '${language}' and browser '${browser}'"
    reportTitle="Report file for tests executed on stage '${STAGE}' with language '${language}' and browser '${browser}'" 

    ROBOT_ALL_ARGUMENTS=(
        --logtitle "${logTitle}"
        --reporttitle "${reportTitle}"
        --outputdir ${CURRENT_TEST_RUN_OUTPUT_FOLDER} 
        --variable browser:${browser} 
        --variable language:${language} 
        --variable SCREENSHOT_DIRECTORY:${SCREENSHOT_DIRECTORY}
        --variable REPORT_OUTPUT_FOLDER:${CURRENT_TEST_EXECUTION_OUTPUT_FOLDER}
        "${ROBOT_COMMON_ARGUMENTS[@]}"
    )

    ALL_COMMAND_ENVIRONMENT_VARIABLES=(
        "${COMMAND_ENVIRONMENT_VARIABLES[@]}"
        LANGUAGE=${language}
    )
    
    ${ALL_COMMAND_ENVIRONMENT_VARIABLES[@]} ${COMMAND[@]} ${ROBOT_TESTS_TO_EXECUTE_ARGUMENT[@]} "${ROBOT_ALL_ARGUMENTS[@]}"
    ROBOT_FRAMEWORK_RETURN_CODE=$?

    if [ -d "${SCREENSHOT_DIRECTORY}" ]; then
        cp -r ${SCREENSHOT_DIRECTORY} ${CURRENT_TEST_EXECUTION_OUTPUT_FOLDER}/${SCREENSHOT_SUB_DIRECTORY}
    fi

    i=0
    # Repeat tests until all succeed, or the maximum number of re-runs is reached
    while [ $i -lt ${RETRY_ON_FAILURE} ] &&  [ ${ROBOT_FRAMEWORK_RETURN_CODE} -ne 0 ]
    do
        LAST_TEST_RUN_OUTPUT_FOLDER=${CURRENT_TEST_RUN_OUTPUT_FOLDER}

        i=$((i+1))

        echo "> Try another run ($i of maximum ${RETRY_ON_FAILURE})"
        CURRENT_TEST_RUN_NUMBER=${i}
        CURRENT_TEST_RUN_OUTPUT_FOLDER=${CURRENT_TEST_EXECUTION_OUTPUT_FOLDER}/${TEST_RUN}_${CURRENT_TEST_RUN_NUMBER}
        SCREENSHOT_SUB_DIRECTORY=screenshots_${TEST_RUN}_${CURRENT_TEST_RUN_NUMBER}
        SCREENSHOT_DIRECTORY=${CURRENT_TEST_RUN_OUTPUT_FOLDER}/${SCREENSHOT_SUB_DIRECTORY}
        mkdir -p ${CURRENT_TEST_RUN_OUTPUT_FOLDER}

        ROBOT_TESTS_TO_EXECUTE_ARGUMENT=(--rerunfailed ${LAST_TEST_RUN_OUTPUT_FOLDER}/output.xml)
        ROBOT_ALL_ARGUMENTS=(
            --logtitle "${logTitle}"
            --reporttitle "${reportTitle}"
            --outputdir ${CURRENT_TEST_RUN_OUTPUT_FOLDER} 
            --variable browser:${browser} 
            --variable language:${language} 
            --variable SCREENSHOT_DIRECTORY:${SCREENSHOT_DIRECTORY}
            "${ROBOT_COMMON_ARGUMENTS[@]}"
        )

        ALL_COMMAND_ENVIRONMENT_VARIABLES=(
            "${COMMAND_ENVIRONMENT_VARIABLES[@]}"
            LANGUAGE=${language}
        )
    
        ${ALL_COMMAND_ENVIRONMENT_VARIABLES[@]} ${COMMAND[@]} ${ROBOT_TESTS_TO_EXECUTE_ARGUMENT[@]} "${ROBOT_ALL_ARGUMENTS[@]}"
        
        ROBOT_FRAMEWORK_RETURN_CODE=$?
        TEST_RUN_RESULT_FILES="${TEST_RUN_RESULT_FILES} ${CURRENT_TEST_RUN_OUTPUT_FOLDER}/output.xml"

        if [ -d "${SCREENSHOT_DIRECTORY}" ]; then
            cp -r ${SCREENSHOT_DIRECTORY} ${CURRENT_TEST_EXECUTION_OUTPUT_FOLDER}/${SCREENSHOT_SUB_DIRECTORY}
        fi
    done

    # Merge the results from all tests
    echo "> Merging these files to a single output file: ${TEST_RUN_RESULT_FILES}"
    rebot --logtitle "${logTitle}" --reporttitle "${reportTitle}" --outputdir ${CURRENT_TEST_EXECUTION_OUTPUT_FOLDER} --output output.xml --merge ${TEST_RUN_RESULT_FILES}
    
    # zip results also if executing a test execution from xray
    if  [ ${ZIP_TEST_RUNS} -eq 1 ] || [ ! -z ${testExecutionId} ]; then
        cd ${OUTPUT_DIRECTORY}
        tar -cjf ${REPORT_FOLDER_ID}_${language}_${browser}_${STAGE}.tar.bz2 ${REPORT_FOLDER_ID}_${language}_${browser}_${STAGE}
        cd -
    fi

    # Upload results to Xray
    if [ ! -z ${testExecutionId} ]; then
        rebot --logtitle "${logTitle}" --reporttitle "${reportTitle}" --outputdir ${CURRENT_TEST_EXECUTION_OUTPUT_FOLDER} --output output_small.xml --log NONE --report NONE --removekeywords all ${CURRENT_TEST_EXECUTION_OUTPUT_FOLDER}/output.xml
        upload_results_to_xray ${CURRENT_TEST_EXECUTION_OUTPUT_FOLDER}/output_small.xml ${OUTPUT_DIRECTORY}/${REPORT_FOLDER_ID}_${language}_${browser}_${STAGE}.tar.bz2 ${testExecutionId}
    fi
    echo "###########################################################################################################################"
}

prepare_and_execute_tests()
{
    local testExecutionId=
    if [ $# -eq 1 ]; then
        testExecutionId=$1
    fi

    prepare_test_execution ${testExecutionId}

    for language in "${TEST_ENVIRONMENT_LANGUAGES[@]}"
    do
        for browser in "${TEST_ENVIRONMENT_BROWSERS[@]}"
        do
            execute_tests ${language} ${browser} ${testExecutionId}
        done
    done

    # Archive all results #
    if  [ ${ZIP_TEST_RUNS} -eq 1 ]; then
        tar -cjf ${OUTPUT_DIRECTORY}/${OUTPUT_DIRECTORY}.tar.bz2 ${OUTPUT_DIRECTORY}
    fi
}

log_script_parameters()
{
    ENDTIME=$(date +%s)
    local durationInSeconds=$((${ENDTIME} - ${STARTTIME}))
    local hours=$((${durationInSeconds}/3600))
    local minutes=$((${durationInSeconds}%3600/60))
    local seconds=$((${durationInSeconds}%60))
    local duration="${hours}h:${minutes}m:${seconds}s"
    echo "> It took ${duration} to execute following test cases: ${LIST_OF_TESTS}"
    printArguments
}

do_test_run()
{
    if [ ${CLEAR_OUTPUT_DIRECTORY} -eq 1 ]; then
        rm -rf ${OUTPUT_DIRECTORY}/*
        rm -rf ${TEMPORARY_FOLDER}/*
    fi

    if [ ${#TEST_EXECUTION_IDS[@]} -ne 0 ]; then
        for testExecutionId in "${TEST_EXECUTION_IDS[@]}"
        do
            echo "> Execute tests for test execution id: ${testExecutionId}"
            prepare_and_execute_tests  ${testExecutionId}
        done
    else
        prepare_and_execute_tests
    fi
}

install_pip_packages_and_update_hash_file() {
    local requirementsFile=$1
    local requirmentsFileHash=$2

    echo -e "\t Python requirments have changed. Updating them via pip."
    echo "---------------------------------------------------------------------------------------------------------------------------"
    pip install -r ${requirementsFile}
    echo "---------------------------------------------------------------------------------------------------------------------------"
    sha1sum ${requirementsFile} > ${requirmentsFileHash}
}

check_python_requirements() {
    echo "###########################################################################################################################"
    echo "   _____ _               _    _               _____       _   _                 ";
    echo "  / ____| |             | |  (_)             |  __ \     | | | |                ";
    echo " | |    | |__   ___  ___| | ___ _ __   __ _  | |__) |   _| |_| |__   ___  _ __  ";
    echo " | |    | '_ \ / _ \/ __| |/ / | '_ \ / _\` | | ___/ | | | __| '_ \ / _ \| '_ \ ";
    echo " | |____| | | |  __/ (__|   <| | | | | (_| | | |   | |_| | |_| | | | (_) | | | |";
    echo "  \_____|_| |_|\___|\___|_|\_\_|_| |_|\__, | |_|    \__, |\__|_| |_|\___/|_| |_|";
    echo "                                       __/ |         __/ |                      ";
    echo "                                      |___/         |___/                       ";

    local requirementsFile=${RESOURCE_DIRECTORY}/requirements.txt
    local requirmentsFileHash=${RESOURCE_DIRECTORY}/requirements.sha1

    if [ ! -f ${requirmentsFileHash} ]; then
        install_pip_packages_and_update_hash_file ${requirementsFile} ${requirmentsFileHash}
    fi

    # Do NOT exit on error since we want install or update packages
    set +e
    sha1sum -c "${RESOURCE_DIRECTORY}/requirements.sha1" 2>/dev/null 1>&2
    status=$?
    # Turn on exit on first error again
    set -e
    if [ ${status} -ne 0 ]; then
        install_pip_packages_and_update_hash_file ${requirementsFile} ${requirmentsFileHash}
    else
        echo -e "\t Python requirements are up to date."
    fi

    echo "###########################################################################################################################"
}

####################### From now own worklow starts #######################

    check_python_requirements

    read_configuration "$@"

    check_configuration

    do_test_run

    log_script_parameters

} 2>&1 > >(tee ${PATH_TO_LOG_FILE})

upload_log_file_to_jira_issue

exit ${ROBOT_FRAMEWORK_RETURN_CODE}
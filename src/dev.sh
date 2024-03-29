#!/bin/bash

###############################################################################
#
#  ./dev.sh build/layout/test/package [Debug/Release]
#
###############################################################################

set -e

DEV_CMD=$1
DEV_CONFIG=$2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT_DIR="$SCRIPT_DIR/../_layout"
DOWNLOAD_DIR="$SCRIPT_DIR/../_downloads/netcore2x"
PACKAGE_DIR="$SCRIPT_DIR/../_package"
DOTNETSDK_ROOT="$SCRIPT_DIR/../_dotnetsdk"
DOTNETSDK_VERSION="3.0.100"
DOTNETSDK_INSTALLDIR="$DOTNETSDK_ROOT/$DOTNETSDK_VERSION"
AGENT_VERSION=$(cat agentversion)

pushd "$SCRIPT_DIR"

BUILD_CONFIG="Debug"
if [[ "$DEV_CONFIG" == "Release" ]]; then
    BUILD_CONFIG="Release"
fi

CURRENT_PLATFORM="windows"
if [[ ($(uname) == "Linux") || ($(uname) == "Darwin") ]]; then
    CURRENT_PLATFORM=$(uname | awk '{print tolower($0)}')
fi

if [[ "$CURRENT_PLATFORM" == 'windows' ]]; then
    RUNTIME_ID='win-x64'
    if [[ "$PROCESSOR_ARCHITECTURE" == 'x86' ]]; then
        RUNTIME_ID='win-x86'
    fi
    elif [[ "$CURRENT_PLATFORM" == 'linux' ]]; then
    RUNTIME_ID="linux-x64"
    if command -v uname > /dev/null; then
        CPU_NAME=$(uname -m)
        case $CPU_NAME in
            armv7l) RUNTIME_ID="linux-arm";;
            aarch64) RUNTIME_ID="linux-arm64";;
        esac
    fi
    
    if [ -e /etc/redhat-release ]; then
        redhatRelease=$(</etc/redhat-release)
        if [[ $redhatRelease == "CentOS release 6."* || $redhatRelease == "Red Hat Enterprise Linux Server release 6."* ]]; then
            RUNTIME_ID='rhel.6-x64'
        fi
    fi
    
    elif [[ "$CURRENT_PLATFORM" == 'darwin' ]]; then
    RUNTIME_ID='osx-x64'
fi

# Make sure current platform support publish the dotnet runtime
# Windows can publish win-x86/x64
# Linux can publish linux-x64/arm/rhel.6-x64
# OSX can publish osx-x64
if [[ "$CURRENT_PLATFORM" == 'windows' ]]; then
    if [[ ("$RUNTIME_ID" != 'win-x86') && ("$RUNTIME_ID" != 'win-x64') ]]; then
        echo "Failed: Can't build $RUNTIME_ID package $CURRENT_PLATFORM" >&2
        exit 1
    fi
    elif [[ "$CURRENT_PLATFORM" == 'linux' ]]; then
    if [[ ("$RUNTIME_ID" != 'linux-x64') && ("$RUNTIME_ID" != 'linux-arm') && ("$RUNTIME_ID" != 'linux-arm64') && ("$RUNTIME_ID" != 'rhel.6-x64') ]]; then
        echo "Failed: Can't build $RUNTIME_ID package $CURRENT_PLATFORM" >&2
        exit 1
    fi
    elif [[ "$CURRENT_PLATFORM" == 'darwin' ]]; then
    if [[ ("$RUNTIME_ID" != 'osx-x64') ]]; then
        echo "Failed: Can't build $RUNTIME_ID package $CURRENT_PLATFORM" >&2
        exit 1
    fi
fi

function failed()
{
    local error=${1:-Undefined error}
    echo "Failed: $error" >&2
    popd
    exit 1
}

function warn()
{
    local error=${1:-Undefined error}
    echo "WARNING - FAILED: $error" >&2
}

function checkRC() {
    local rc=$?
    if [ $rc -ne 0 ]; then
        failed "${1} Failed with return code $rc"
    fi
}

function heading()
{
    echo
    echo
    echo "-----------------------------------------"
    echo "  ${1}"
    echo "-----------------------------------------"
}

function build ()
{
    heading "Building ..."
    dotnet msbuild -t:Build -p:PackageRuntime="${RUNTIME_ID}" -p:BUILDCONFIG="${BUILD_CONFIG}" -p:AgentVersion="${AGENT_VERSION}" || failed build
    
    mkdir -p "${LAYOUT_DIR}/bin/en-US"
    grep --invert-match '^ *"CLI-WIDTH-' ./Misc/layoutbin/en-US/strings.json > "${LAYOUT_DIR}/bin/en-US/strings.json"
}

function layout ()
{
    heading "Create layout ..."
    dotnet msbuild -t:layout -p:PackageRuntime="${RUNTIME_ID}" -p:BUILDCONFIG="${BUILD_CONFIG}" -p:AgentVersion="${AGENT_VERSION}" || failed build
    
    mkdir -p "${LAYOUT_DIR}/bin/en-US"
    grep --invert-match '^ *"CLI-WIDTH-' ./Misc/layoutbin/en-US/strings.json > "${LAYOUT_DIR}/bin/en-US/strings.json"
    
    #change execution flag to allow running with sudo
    if [[ ("$CURRENT_PLATFORM" == "linux") || ("$CURRENT_PLATFORM" == "darwin") ]]; then
        chmod +x "${LAYOUT_DIR}/bin/Agent.Listener"
        chmod +x "${LAYOUT_DIR}/bin/Agent.Worker"
        chmod +x "${LAYOUT_DIR}/bin/Agent.PluginHost"
        chmod +x "${LAYOUT_DIR}/bin/installdependencies.sh"
    fi
    
    heading "Setup externals folder for $RUNTIME_ID agent's layout"
    bash ./Misc/externals.sh $RUNTIME_ID || checkRC externals.sh
}

function runtest ()
{
    heading "Testing ..."
    
    if [[ ("$CURRENT_PLATFORM" == "linux") || ("$CURRENT_PLATFORM" == "darwin") ]]; then
        ulimit -n 1024
    fi
    
    dotnet msbuild -t:test -p:PackageRuntime="${RUNTIME_ID}" -p:BUILDCONFIG="${BUILD_CONFIG}" -p:AgentVersion="${AGENT_VERSION}" || failed "failed tests"
}

function package ()
{
    if [ ! -d "${LAYOUT_DIR}/bin" ]; then
        echo "You must build first.  Expecting to find ${LAYOUT_DIR}/bin"
    fi
    
    agent_ver=$("${LAYOUT_DIR}/bin/Agent.Listener" --version | tail -n 1) || failed "version"
    agent_pkg_name="vsts-agent-${RUNTIME_ID}-${agent_ver}"
    
    # TEMPORARY - need to investigate why Agent.Listener --version is throwing an error on OS X
    if [ $("${LAYOUT_DIR}/bin/Agent.Listener" --version | wc -l) -gt 1 ]; then
        echo "Error thrown during --version call!"
        log_file=$("${LAYOUT_DIR}/bin/Agent.Listener" --version | head -n 2 | tail -n 1 | cut -d\  -f6)
        cat "${log_file}"
    fi
    # END TEMPORARY
    
    heading "Packaging ${agent_pkg_name}"
    
    rm -Rf "${LAYOUT_DIR:?}/_diag"
    find "${LAYOUT_DIR}/bin" -type f -name '*.pdb' -delete
    
    mkdir -p "$PACKAGE_DIR"
    rm -Rf "${PACKAGE_DIR:?}"/*
    
    pushd "$PACKAGE_DIR" > /dev/null
    
    if [[ ("$CURRENT_PLATFORM" == "linux") || ("$CURRENT_PLATFORM" == "darwin") ]]; then
        tar_name="${agent_pkg_name}.tar.gz"
        echo "Creating $tar_name in ${LAYOUT_DIR}"
        tar -czf "${tar_name}" -C "${LAYOUT_DIR}" .
        elif [[ ("$CURRENT_PLATFORM" == "windows") ]]; then
        zip_name="${agent_pkg_name}.zip"
        echo "Convert ${LAYOUT_DIR} to Windows style path"
        window_path=${LAYOUT_DIR:1}
        window_path=${window_path:0:1}:${window_path:1}
        echo "Creating $zip_name in ${window_path}"
        powershell -NoLogo -Sta -NoProfile -NonInteractive -ExecutionPolicy Unrestricted -Command "Add-Type -Assembly \"System.IO.Compression.FileSystem\"; [System.IO.Compression.ZipFile]::CreateFromDirectory(\"${window_path}\", \"${zip_name}\")"
    fi
    
    popd > /dev/null
}

if [[ (! -d "${DOTNETSDK_INSTALLDIR}") || (! -e "${DOTNETSDK_INSTALLDIR}/.${DOTNETSDK_VERSION}") || (! -e "${DOTNETSDK_INSTALLDIR}/dotnet") ]]; then
    
    # Download dotnet SDK to ../_dotnetsdk directory
    heading "Ensure Dotnet SDK"
    
    # _dotnetsdk
    #           \1.0.x
    #                            \dotnet
    #                            \.1.0.x
    echo "Download dotnetsdk into ${DOTNETSDK_INSTALLDIR}"
    rm -Rf "${DOTNETSDK_DIR}"
    
    # run dotnet-install.ps1 on windows, dotnet-install.sh on linux
    if [[ ("$CURRENT_PLATFORM" == "windows") ]]; then
        echo "Convert ${DOTNETSDK_INSTALLDIR} to Windows style path"
        sdkinstallwindow_path=${DOTNETSDK_INSTALLDIR:1}
        sdkinstallwindow_path=${sdkinstallwindow_path:0:1}:${sdkinstallwindow_path:1}
        powershell -NoLogo -Sta -NoProfile -NonInteractive -ExecutionPolicy Unrestricted -Command "& \"./Misc/dotnet-install.ps1\" -Version ${DOTNETSDK_VERSION} -InstallDir \"${sdkinstallwindow_path}\" -NoPath; exit \$LastExitCode;" || checkRC dotnet-install.ps1
    else
        bash ./Misc/dotnet-install.sh --version ${DOTNETSDK_VERSION} --install-dir "${DOTNETSDK_INSTALLDIR}" --no-path || checkRC dotnet-install.sh
    fi
    
    echo "${DOTNETSDK_VERSION}" > "${DOTNETSDK_INSTALLDIR}/.${DOTNETSDK_VERSION}"
fi

echo "Prepend ${DOTNETSDK_INSTALLDIR} to %PATH%"
export PATH=${DOTNETSDK_INSTALLDIR}:$PATH

heading "Dotnet SDK Version"
dotnet --version

heading "Pre-cache external resources for $RUNTIME_ID package ..."
bash ./Misc/externals.sh $RUNTIME_ID "Pre-Cache" || checkRC "externals.sh Pre-Cache"

if [[ "$CURRENT_PLATFORM" == 'windows' ]]; then
    vswhere=$(find "$DOWNLOAD_DIR" -name vswhere.exe | head -1)
    vs_location=$("$vswhere" -latest -property installationPath)
    msbuild_location="$vs_location""\MSBuild\15.0\Bin\msbuild.exe"
    
    if [[ ! -e "${msbuild_location}" ]]; then
        msbuild_location="$vs_location""\MSBuild\Current\Bin\msbuild.exe"
        
        if [[ ! -e "${msbuild_location}" ]]; then
            failed "Can not find msbuild location, failing build"
        fi
    fi
    
    export DesktopMSBuild="$msbuild_location"
fi

case $DEV_CMD in
    "build") build;;
    "b") build;;
    "test") runtest;;
    "t") runtest;;
    "layout") layout;;
    "l") layout;;
    "package") package;;
    "p") package;;
    *) echo "Invalid cmd.  Use build(b), test(t), layout(l) or package(p)";;
esac

popd
echo
echo Done.
echo
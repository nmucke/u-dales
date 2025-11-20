#!/usr/bin/env bash

set -e

# Usage: ./tools/build_preprocessing.sh [common / icl / delftblue]

if [ ! -d tools ]; then
    echo "Please run this script from being inside the u-dales folder"
    exit 1
fi

# Initialize modules if available (for HPC systems)
if command -v module &> /dev/null; then
    # ensure module command is initialized inside non-interactive shell
    if [ -f /etc/profile.d/modules.sh ]; then
        source /etc/profile.d/modules.sh
    fi
fi

cd tools/View3D
mkdir -p build
cd build

system=$1
if [ "$system" == "icl" ]
then
    module load cmake/3.18.2
elif [ "$system" == "delftblue" ]
then
    echo "Building View3D on DelftBlue."
    # Load DelftBlue software stack
    if module avail 2024r1 &> /dev/null; then
        module load 2024r1
    elif module avail 2023r1 &> /dev/null; then
        module load 2023r1
    fi
    module load cmake
elif [ "$system" == "common" ]
then
    echo "Building View3D on local system."
    # Check if cmake is available
    if ! command -v cmake &> /dev/null; then
        echo "Error: cmake not found. Please install cmake or use a platform-specific option (e.g., 'delftblue' or 'icl')."
        exit 1
    fi
else
    echo "Error: Configuration '$system' is not available."
    echo "Available configurations: common, icl, delftblue"
    exit 1
fi

cmake ..
echo "View3D configuration complete."

make

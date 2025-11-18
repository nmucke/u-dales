#!/usr/bin/env bash

# uDALES (https://github.com/uDALES/u-dales).

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Copyright (C) 2016-2019 the uDALES Team.

set -e

# Usage: ./tools/build_executable.sh [icl, archer, cca, common] [debug, release]

if [ ! -d src ]; then
    echo "Please run this script from being inside the u-dales folder"
    exit 1
fi

capitalize() {
    echo $* | sed -e "s/\b\(.\)/\u\1/g"
}

#echo "--- Debug info ---"
#echo "env: " `env`
#echo "PATH: " ${PATH}

NPROC=4 # TODO: make into a arg var.
system=$1
build_type=$2


if [ $system == "icl" ]
then
    module load intel/2025a netCDF/4.9.2-iimpi-2023a netCDF-Fortran/4.6.1-iimpi-2023a FFTW/3.3.9-intel-2021a CMake/3.29.3-GCCcore-13.3.0 git/2.45.1-GCCcore-13.3.0
    FC=mpiifort
    NETCDF_DIR=/sw-eb/software/netCDF/4.9.2-iimpi-2023a
    NETCDF_FORTRAN_DIR=/sw-eb/software/netCDF-Fortran/4.6.1-iimpi-2023a

elif [ $system == "archer" ]
then
    module load cmake cray-hdf5 cray-netcdf cray-fftw
    FC=ftn
    NETCDF_DIR=$NETCDF_DIR
    NETCDF_FORTRAN_DIR=$NETCDF_FORTRAN_DIR
    #FFTW_DOUBLE_LIB=/opt/cray/pe/fftw/3.3.8.9/x86_rome/lib/libfftw3.so
    #FFTW_FLOAT_LIB=/opt/cray/pe/fftw/3.3.8.9/x86_rome/lib/libfftw3f.so

elif [ $system == "cca" ]
then
    module load git cmake
    FC=ftn
    NETCDF_DIR=$NETCDF_DIR
    NETCDF_FORTRAN_DIR=$NETCDF_DIR

elif [ $system == "common" ]
then
    FC=
    NETCDF_DIR=
    NETCDF_FORTRAN_DIR=

elif [ $system == "delftblue" ]
then
    module load 2024r1
    module load openmpi
    module load cmake
    module load netcdf-c netcdf-fortran fftw
    export CPATH=$FFTW_ROOT/include:${CPATH}
    FC=mpifort
    NETCDF_DIR=$(nc-config --prefix)
    NETCDF_FORTRAN_DIR=$(nf-config --prefix)
    # Override FPE trapping flags to avoid crashes with NetCDF library
    # NetCDF operations can trigger FPEs that are safe to ignore
    export CMAKE_Fortran_FLAGS_OVERRIDE="-fdefault-real-8 -ffree-line-length-none -std=f2008"
    # Flag to indicate we need to patch CMakeLists.txt
    export PATCH_CMAKE_LISTS=1

else
    echo "This configuration is not avalable"
    exit 1
fi


# Configure and Build
path_to_build_dir="$(pwd)/build/$build_type"
# For DelftBlue, clean build directory to ensure FPE flags override is applied
if [ "$system" == "delftblue" ] && [ -d "$path_to_build_dir" ]; then
    echo "Cleaning DelftBlue build directory to apply FPE flags override..."
    rm -rf "$path_to_build_dir"
fi
mkdir -p $path_to_build_dir
pushd $path_to_build_dir
cmake_build_type="$(capitalize $build_type)"

# Patch CMakeLists.txt files to remove FPE flags if needed (for DelftBlue)
if [ ! -z "$PATCH_CMAKE_LISTS" ] && [ "$PATCH_CMAKE_LISTS" == "1" ]; then
    echo "Temporarily patching CMakeLists.txt files to remove FPE trapping flags..."
    # Patch main CMakeLists.txt
    CMAKELISTS_FILE="../../CMakeLists.txt"
    if [ -f "$CMAKELISTS_FILE" ]; then
        cp "$CMAKELISTS_FILE" "${CMAKELISTS_FILE}.bak"
        sed -i 's/-ffpe-trap=invalid,zero,overflow //g' "$CMAKELISTS_FILE"
        RESTORE_CMAKE_LISTS=1
    fi
    # Patch 2decomp-fft CMakeLists.txt
    DECOMP_CMAKE="../../2decomp-fft/CMakeLists.txt"
    if [ -f "$DECOMP_CMAKE" ]; then
        cp "$DECOMP_CMAKE" "${DECOMP_CMAKE}.bak"
        sed -i 's/-ffpe-trap=invalid,zero,overflow //g' "$DECOMP_CMAKE"
        RESTORE_DECOMP_CMAKE=1
    fi
fi

# Build cmake command - add FPE flags override if set (e.g., for DelftBlue to avoid NetCDF FPE crashes)
if [ ! -z "$CMAKE_Fortran_FLAGS_OVERRIDE" ]; then
    FC=$FC cmake -DNETCDF_DIR=$NETCDF_DIR \
                 -DNETCDF_FORTRAN_DIR=$NETCDF_FORTRAN_DIR \
                 -DCMAKE_BUILD_TYPE=$cmake_build_type \
	         -DFFTW_DOUBLE_OPENMP_LIB=$FFTW_DOUBLE_LIB \
	         -DFFTW_FLOAT_OPENMP_LIB=$FFTW_FLOAT_OPENMP_LIB \
                 -DCMAKE_Fortran_FLAGS:STRING="$CMAKE_Fortran_FLAGS_OVERRIDE" \
                  ../../ 2>&1 | tee -a $path_to_build_dir/config.log
else
    FC=$FC cmake -DNETCDF_DIR=$NETCDF_DIR \
                 -DNETCDF_FORTRAN_DIR=$NETCDF_FORTRAN_DIR \
                 -DCMAKE_BUILD_TYPE=$cmake_build_type \
	         -DFFTW_DOUBLE_OPENMP_LIB=$FFTW_DOUBLE_LIB \
	         -DFFTW_FLOAT_OPENMP_LIB=$FFTW_FLOAT_OPENMP_LIB \
                  ../../ 2>&1 | tee -a $path_to_build_dir/config.log
fi
make -j$NPROC 2>&1 | tee -a $path_to_build_dir/build.log
popd

# Restore CMakeLists.txt files if they were patched
if [ ! -z "$RESTORE_CMAKE_LISTS" ] && [ "$RESTORE_CMAKE_LISTS" == "1" ]; then
    echo "Restoring original CMakeLists.txt files..."
    CMAKELISTS_FILE="CMakeLists.txt"
    if [ -f "${CMAKELISTS_FILE}.bak" ]; then
        mv "${CMAKELISTS_FILE}.bak" "$CMAKELISTS_FILE"
    fi
    if [ ! -z "$RESTORE_DECOMP_CMAKE" ] && [ "$RESTORE_DECOMP_CMAKE" == "1" ]; then
        DECOMP_CMAKE="2decomp-fft/CMakeLists.txt"
        if [ -f "${DECOMP_CMAKE}.bak" ]; then
            mv "${DECOMP_CMAKE}.bak" "$DECOMP_CMAKE"
        fi
    fi
fi

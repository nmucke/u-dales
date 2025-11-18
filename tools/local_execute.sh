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

# Usage: ./tools/local_execute.sh <PATH_TO_CASE>

set -e

if (( $# < 1 ))
then
    echo "The path to case folder must be set."
    exit
fi

## go to experiment directory
pushd $1
inputdir=$(pwd)

## set experiment number via path
exp="${inputdir: -3}"

echo "Setting up uDALES for case $exp..."

## read in additional variables
if [ -f config.sh ]; then
    source config.sh
fi

## check if required variables are set
## or set default if not
if [ -z $NCPU ]; then
    NCPU=1
fi;
if [ -z $DA_WORKDIR ]; then
    echo "Output top-level directory DA_WORKDIR must be set"
    exit
fi;
if [ -z $DA_BUILD ]; then
    echo "Executable DA_BUILD must be set"
    exit
fi;
if [ -z $DA_TOOLSDIR ]; then
    echo "Script directory DA_TOOLSDIR must be set"
    exit
fi;

## set the experiment output directory
outdir=$DA_WORKDIR/$exp

echo "Starting job for case $exp..."

## copy files to output directory
mkdir -p $outdir
cp -r ./* $outdir

## go to execution and output directory
pushd $outdir

## Load MPI modules if on DelftBlue (check if module command exists)
if command -v module &> /dev/null; then
    # ensure module command is initialized inside non-interactive shell
    if [ -f /etc/profile.d/modules.sh ]; then
        source /etc/profile.d/modules.sh
    fi
    # Try to detect if we're on DelftBlue and load appropriate modules
    if module avail 2024r1 &> /dev/null || module avail 2023r1 &> /dev/null; then
        # Load modules compatible with the build (MPI + NetCDF + FFTW)
        if module avail 2024r1 &> /dev/null; then
            module load 2024r1 openmpi netcdf-c netcdf-fortran fftw 2>/dev/null || true
        elif module avail 2023r1 &> /dev/null; then
            module load 2023r1 openmpi netcdf-c netcdf-fortran fftw 2>/dev/null || true
        fi
    fi
fi

export HDF5_USE_FILE_LOCKING=FALSE

## execute program with mpi
# Try mpirun first (OpenMPI), then mpiexec, then srun
if command -v mpirun &> /dev/null; then
    mpirun -n $NCPU --oversubscribe $DA_BUILD namoptions.$exp 2>&1 | tee -a run.$exp.log
elif command -v mpiexec &> /dev/null; then
    mpiexec -n $NCPU --oversubscribe $DA_BUILD namoptions.$exp 2>&1 | tee -a run.$exp.log
elif command -v srun &> /dev/null; then
    srun -n $NCPU $DA_BUILD namoptions.$exp 2>&1 | tee -a run.$exp.log
else
    echo "Error: No MPI launcher found (mpirun, mpiexec, or srun)"
    exit 1
fi

## Merge output files across outputs.
if (($NCPU > 1 )); then
    echo "Merging outputs across cores into one..."
    $DA_TOOLSDIR/gather_outputs.sh $outdir
fi

popd

echo "Simulation for case $exp ran sucesfully!"

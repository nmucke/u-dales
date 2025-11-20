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

## Check available memory and warn if low (approximate check)
if command -v free &> /dev/null; then
    AVAIL_MEM_MB=$(free -m | awk '/^Mem:/ {print $7}')
    # Estimate memory needed: domain size (256^3) * variables * bytes per float * processes
    # This is a rough estimate - actual usage depends on many factors
    ESTIMATED_MEM_MB=$((256 * 256 * 256 * 10 * 4 / 1024 / 1024 / $NCPU))
    if [ $AVAIL_MEM_MB -lt $((ESTIMATED_MEM_MB * 2)) ]; then
        echo "Warning: Available memory ($AVAIL_MEM_MB MB) may be insufficient for this simulation"
        echo "Estimated memory per process: ~$ESTIMATED_MEM_MB MB"
        echo "Consider:"
        echo "  1. Reducing domain size (itot, jtot, ktot in namoptions)"
        echo "  2. Using fewer processes (reduce NCPU in config.sh)"
        echo "  3. Running via job scheduler with proper memory allocation"
    fi
fi

## execute program with mpi
# Check if we're in a Slurm job (even if env vars aren't set)
IN_SLURM_JOB=false
if [ ! -z "$SLURM_JOB_ID" ]; then
    IN_SLURM_JOB=true
elif command -v scontrol &> /dev/null; then
    # Try to detect if we're in a job by checking if scontrol works
    # This handles cases where SLURM_JOB_ID isn't set but we're in an interactive job
    if scontrol show job $$ &> /dev/null 2>&1 || scontrol show job $PPID &> /dev/null 2>&1; then
        IN_SLURM_JOB=true
    fi
fi

# Prefer mpirun when MPI modules are loaded (works in any environment including Slurm jobs)
# Use srun only if not in a job and explicitly needed
if command -v mpirun &> /dev/null; then
    echo "Using mpirun with $NCPU processes"
    # In Slurm jobs, OpenMPI may not detect all allocated CPUs from --cpus-per-task
    # Use --oversubscribe to tell OpenMPI to allow more processes than detected slots
    # This is safe when running inside a Slurm job with proper CPU allocation
    if [ "$IN_SLURM_JOB" = true ]; then
        echo "Inside Slurm job: using --oversubscribe to use allocated CPUs"
        mpirun -n $NCPU --oversubscribe $DA_BUILD namoptions.$exp 2>&1 | tee -a run.$exp.log
    else
        mpirun -n $NCPU --oversubscribe $DA_BUILD namoptions.$exp 2>&1 | tee -a run.$exp.log
    fi
elif command -v mpiexec &> /dev/null; then
    echo "Using mpiexec with $NCPU processes"
    if [ "$IN_SLURM_JOB" = true ]; then
        mpiexec -n $NCPU $DA_BUILD namoptions.$exp 2>&1 | tee -a run.$exp.log
    else
        mpiexec -n $NCPU --oversubscribe $DA_BUILD namoptions.$exp 2>&1 | tee -a run.$exp.log
    fi
elif [ "$IN_SLURM_JOB" = true ] && command -v srun &> /dev/null; then
    # Only use srun if we're in a Slurm job and no MPI launcher available
    echo "Using srun with $NCPU processes (Slurm job detected)"
    # Get available CPUs from the job allocation if possible
    if [ ! -z "$SLURM_CPUS_ON_NODE" ] && [ "$SLURM_CPUS_ON_NODE" -lt "$NCPU" ]; then
        echo "Warning: Requested $NCPU CPUs but only $SLURM_CPUS_ON_NODE available. Adjusting..."
        ACTUAL_CPU=$SLURM_CPUS_ON_NODE
    else
        ACTUAL_CPU=$NCPU
    fi
    srun -n $ACTUAL_CPU $DA_BUILD namoptions.$exp 2>&1 | tee -a run.$exp.log
elif command -v srun &> /dev/null; then
    echo "Warning: Using srun without a job allocation - this may fail if insufficient resources"
    srun -n $NCPU $DA_BUILD namoptions.$exp 2>&1 | tee -a run.$exp.log
else
    echo "Error: No MPI launcher found (mpirun, mpiexec, or srun)"
    echo "Make sure MPI modules are loaded or MPI is available in PATH"
    echo "Try: module load 2024r1 openmpi"
    exit 1
fi

# Check if simulation completed successfully
SIM_EXIT_CODE=${PIPESTATUS[0]}
if [ $SIM_EXIT_CODE -ne 0 ]; then
    echo ""
    echo "=== Simulation Error Summary ==="
    echo "Simulation exited with code $SIM_EXIT_CODE"
    
    # Check log for various error conditions
    if grep -qi "not enough slots available" run.$exp.log 2>/dev/null || \
       grep -qi "more processors requested than permitted" run.$exp.log 2>/dev/null || \
       grep -qi "unable to create step" run.$exp.log 2>/dev/null; then
        echo ""
        echo "ERROR: Resource allocation issue"
        echo ""
        if grep -qi "not enough slots available" run.$exp.log 2>/dev/null; then
            echo "OpenMPI could not detect enough CPU slots for $NCPU processes."
            echo ""
            echo "This can happen in Slurm jobs when OpenMPI doesn't detect allocated CPUs."
            echo ""
            echo "Solutions:"
            echo "  1. Request your job with --ntasks=$NCPU (instead of --ntasks=1 --cpus-per-task=10):"
            echo "     srun --job-name=\"int_job\" --partition=compute --time=00:30:00 --ntasks=$NCPU --mem-per-cpu=3968MB --pty bash"
            echo ""
            echo "  2. Or use --oversubscribe (script should already use this)"
            echo ""
        else
            echo "The requested number of CPUs ($NCPU) exceeds what's available in the current allocation."
            echo ""
            echo "Solutions:"
            echo "  1. Reduce NCPU in config.sh to match available CPUs"
            echo "  2. Request a new job allocation with sufficient CPUs:"
            echo "     srun --pty --mem=32G --cpus-per-task=$NCPU --time=2:00:00 bash"
            echo ""
        fi
    elif grep -q "signal 9" run.$exp.log 2>/dev/null || grep -q "Killed" run.$exp.log 2>/dev/null; then
        echo ""
        echo "ERROR: Process was killed (likely out of memory)"
        echo ""
        echo "Solutions:"
        echo "  1. Request an interactive compute node with sufficient memory:"
        echo "     srun --pty --mem=32G --cpus-per-task=4 bash"
        echo "     Then run your script inside that session"
        echo ""
        echo "  2. Reduce domain size in namoptions.$exp:"
        echo "     Change itot, jtot, ktot from 256 to a smaller value (e.g., 128)"
        echo ""
        echo "  3. Reduce number of processes in config.sh:"
        echo "     Change NCPU from 4 to 2 or 1"
        echo ""
        echo "  4. Use a batch job script with proper memory allocation"
    else
        echo ""
        echo "Possible causes:"
        echo "  - Out of memory (check dmesg or system logs)"
        echo "  - Resource limits exceeded"
        echo "  - Input/configuration error"
        echo "  - Check run.$exp.log for detailed error messages"
    fi
    echo ""
fi

## Merge output files across outputs.
if (($NCPU > 1 )); then
    # Check if NCO tools are available for merging
    if command -v ncpdq &> /dev/null && command -v ncrcat &> /dev/null && command -v ncks &> /dev/null; then
        echo "Merging outputs across cores into one..."
        $DA_TOOLSDIR/gather_outputs.sh $outdir
    else
        echo "Warning: NCO tools (ncpdq, ncrcat, ncks) not found in PATH."
        echo "Skipping output merging. Individual output files from each core are available in $outdir"
        echo "To merge outputs later, load NCO module and run: $DA_TOOLSDIR/gather_outputs.sh $outdir"
    fi
fi

popd

echo "Simulation for case $exp ran sucesfully!"

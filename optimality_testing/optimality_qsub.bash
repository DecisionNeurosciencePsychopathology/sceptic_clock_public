#!/usr/bin/env sh

# -l nodes=72:ppn=1
# -l nodes=comp-hm-20:ppn=10+comp-hm-21:ppn=10+comp-hm-22:ppn=10
#PBS -l nodes=1:ppn=40
#PBS -l walltime=40:00:00
#PBS -A mnh5174_collab
#PBS -j oe
#PBS -M michael.hallquist@psu.edu
#PBS -m abe

env
cd $PBS_O_WORKDIR

module load matlab

matlab -nodisplay -r optimize_and_calculate_model_costs


#!/bin/bash

export NSIM_HOME=/opt/ARC/nSIM_64
. $NSIM_HOME/systemc/scripts/setup.sh
cd $NSIM_HOME/systemc/examples/Linux_VP
export SC_SIGNAL_WRITE_CHECK=DISABLE
export LM_LICENSE_FILE=27000@bertie
./sc_top

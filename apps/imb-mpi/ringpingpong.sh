#!/bin/bash
MPI=${1-impi2018}
MODE=${2-ring}
TYPE=${3-latency}
set -o pipefail

[[ -n $PBS_NODEFILE ]] && { ISPBS=true; JOBID=$PBS_JOBID; }
[[ -n $SLURM_NODELIST ]] && { ISSLURM=true; JOBID=$SLURM_JOBID; }

if [ $TYPE == "latency" ]; then
   MSGLOG="9:10"
elif [ $TYPE == "bandwidth" ]; then
   MSGLOG="22:24"
else
   echo "Error: Do not recognize MSGLOG option: $MSGLOG"
   exit 1
fi

# Retrieve the VM size
AZHPC_VMSIZE=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2018-10-01" | jq -r '.compute.vmSize')
export AZHPC_VMSIZE=${AZHPC_VMSIZE,,}

case $MPI in
    impi2016)
        source /opt/intel/impi/5.1.3.223/bin64/mpivars.sh
        export I_MPI_FABRICS="shm:dapl"
        export I_MPI_FALLBACK_DEVICE=0
        export I_MPI_DAPL_PROVIDER=ofa-v2-ib0
        export I_MPI_DEBUG=4
        [[ "$ISPBS" = true ]] && mpi_options="-np 2 -ppn 1"
        host_option="-hosts"
        if [ -z $MPI_BIN ]; then
            IMB_ROOT=$I_MPI_ROOT/intel64/bin
        else
            IMB_ROOT=$MPI_BIN
        fi
    ;;
    impi2018)
        source /etc/profile
        module use /usr/share/Modules/modulefiles
        module load mpi/impi
        #source $MPI_BIN/mpivars.sh
        export I_MPI_FABRICS="shm:ofa"
        export I_MPI_FALLBACK_DEVICE=0
        export I_MPI_DEBUG=4
        [[ "$ISPBS" = true ]] && mpi_options="-np 2 -ppn 1"
        host_option="-hosts"
        if [ -z $MPI_BIN ]; then
            IMB_ROOT=$I_MPI_ROOT/intel64/bin
        else
            IMB_ROOT=$MPI_BIN
        fi
    ;;
    impi2019)
        source /etc/profile
        module use /usr/share/Modules/modulefiles
        module load mpi/impi-2019
        #source $MPI_BIN/mpivars.sh -ofi_internal
        export I_MPI_FABRICS="shm:ofi"
        #export I_MPI_FALLBACK_DEVICE=0
        export I_MPI_DEBUG=4
        export FI_PROVIDER=mlx
        [[ "$ISPBS" = true ]] && mpi_options="-np 2 -ppn 1"
        host_option="-hosts"
        if [ -z $MPI_BIN ]; then
            IMB_ROOT=$I_MPI_ROOT/intel64/bin
        else
            IMB_ROOT=$MPI_BIN
        fi
    ;;
    ompi)
        source /etc/profile
        module use /usr/share/Modules/modulefiles
        module load mpi/hpcx

        mpi_options=" -bind-to core"
        mpi_options+=" -mca coll_hcoll_enable 1 -x HCOLL_ENABLE_MCAST_ALL=1"
        [[ "$ISPBS" = true ]] && mpi_options+=" -npernode 1 -np 2"
        host_option="-host"
        case $AZHPC_VMSIZE in
            standard_hb120rs_v2|standard_hb60rs)
                mpi_options+=" -x HCOLL_SBGP_BASESMSOCKET_GROUP_BY=numa"
            ;;
        esac
        IMB_ROOT=$HPCX_MPI_TESTS_DIR/imb
    ;;
esac

# affinity
numactl_options=" numactl --cpunodebind 0"

if [[ "$ISPBS" = true ]]; then
    hostlist=$(pwd)/hosts.$JOBID
    sort -u $PBS_NODEFILE > $hostlist
    # remove .internal.cloudapp.net from node names added by PBS in the PBS_NODEFILE
    sed -i 's/.internal.cloudapp.net//g' $hostlist
elif [[ "$ISSLURM" = true ]]; then
    scontrol show hostname $SLURM_NODELIST > $(pwd)/hosts.$JOBID
    hostlist=$(pwd)/hosts.$JOBID
fi

case $MODE in
    ring) # one to neighbour
        src=$(tail -n 1 $hostlist)
        # -msglog 9:10 is for 512 and 1024 bytes message size only
        for dst in $(<$hostlist); do
            mpirun $host_option $src,$dst \
                $mpi_options $numactl_options \
                $IMB_ROOT/IMB-MPI1 PingPong -msglog $MSGLOG > ${src}_to_${dst}_ringpingpong.$JOBID.log
            src=$dst
        done
    ;;
    half) # one to each one way
        cp $hostlist desthosts.$JOBID
        for src in $(<$hostlist); do
            # delete the first line
            sed -i '1d' desthosts.$JOBID
            for dst in $(<desthosts.$JOBID); do
                mpirun $host_option $src,$dst \
                    $mpi_options $numactl_options \
                    $IMB_ROOT/IMB-MPI1 PingPong -msglog $MSGLOG > ${src}_to_${dst}_ringpingpong.$JOBID.log
            done
        done
        rm desthosts.$JOBID
    ;;
esac

# clean up
rm $hostlist

if [ $TYPE == "latency" ]; then
echo "Ring Ping Pong Results (1024 bytes)"
printf "%-20s %-20s %10s\n" "Source" "Destination" "Time [usec]"
grep "^         1024 " *_ringpingpong.$JOBID.log \
    | tr -s ' ' | cut -d ' ' -f 1,4 \
    | sed 's/_to_/ /g;s/_ringpingpong[^:]*://g' \
    | sort -nk 3 \
    | xargs printf "%-20s %-20s %10s\n" | tee output.log
else
echo "Ring Ping Pong Bandwidth Results (16777216 bytes)"
printf "%-20s %-20s %10s\n" "Source" "Destination" "Mbytes/sec"
grep "^ *16777216 " *_ringpingpong.$JOBID.log \
    | tr -s ' ' | cut -d ' ' -f 1,5 \
    | sed 's/_to_/ /g;s/_ringpingpong[^:]*://g' \
    | sort -nk 3 \
    | xargs printf "%-20s %-20s %10s\n" | tee bandwidth_output.log
fi

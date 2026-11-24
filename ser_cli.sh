# /bin/bash
# usage:
#       server: ../ser_cli.sh server
#       client: ../ser_cli.sh machine_id num_cli num_coro num_machine
#       client_0: ../ser_cli.sh 0 1 1 2
# Cluster defaults: memserver16 server / bfhost_72 client, IB 10.10.1.16, gid 0
if [ "$1" = "server" ]
then
    echo "server"
    # ./ser_cli_var_kv --server \
    ./ser_cli --server \
    --gid_idx 0 \
    --max_coro 256 --cq_size 64 \
    --mem_size 85899345920
else
    echo "machine" $1

    for num_cli in `seq $2 $2`;do
        for num_coro in `seq 1 $3`;do
            for load_num in 10000000;do
                echo "num_cli" $num_cli "num_coro" $num_coro "load_num" $load_num
                # ./ser_cli_var_kv \
                ./ser_cli \
                --server_ip 10.10.1.16 --num_machine $4 --num_cli $num_cli --num_coro $num_coro \
                --gid_idx 0 \
                --max_coro 256 --cq_size 64 \
                --machine_id $1  \
                --load_num $load_num \
                --num_op 1000000 \
                --pattern_type 0 \
                --insert_frac 0.0 \
                --read_frac   1.0 \
                --update_frac  0.0 \
                --delete_frac  0.0 \
                --read_size     64
            done
        done
    done
fi

# YCSB A : read:0.5,insert:0.5 zipfian(2)
# YCSB B : read:0.95,update:0.05 zipfian(2)
# YCSB C : read:1.0,update:0.0 zipfian(2)
# YCSB D : read:0.95,insert:0.05 latest(3)
# YCSB E : scan -- not used
# YCSB F : read:0.5,rmw:0.5 zipfian(2) -- RMW, not used

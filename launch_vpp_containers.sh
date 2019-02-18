#!/bin/bash

if [ $USER != "root"  ] ; then
    echo "Restarting script with sudo..."
    sudo $0 ${*}
    exit
fi

exposedockernetns () {
	if [ "$1" == "" ]; then
  	  echo "usag<Plug>yankstack_after_pastee: $0 <container_name>"
	  echo "Exposes the netns of a docker container to the host"
          exit 1
        fi

        pid=`docker inspect -f '{{.State.Pid}}' $1`
        ln -s /proc/$pid/ns/net /var/run/netns/$1

        echo "netns of ${1} exposed as /var/run/netns/${1}"

        echo "try: ip netns exec ${1} ip addr list"
   return 0
}

dockerrmf () {
	#Cleanup all containers on the host (dead or alive).
	docker kill `docker ps --no-trunc -aq` ; docker rm `docker ps --no-trunc -aq`
}

if_per_container=2
container_prefix="sity"
interface_prefix="sity"
max_containers=2
ip_msb="181"

delete_all() {
    container_index=0
    while [ $container_index -lt $max_containers ]
    do
        sep="_"
        name="$container_prefix$sep$container_index"
        ifnum=0

        #delete intface associated with each container
        while [ $ifnum -lt $if_per_container ]
        do
            sudo vppctl delete host-interface name $interface_prefix$container_index$ifnum > /dev/null 2>&1
            ip link delete dev veth_$interface_prefix$container_index$ifnum  > /dev/null 2>&1
            ifnum=$((ifnum+1))
        done

        docker kill $name  > /dev/null 2>&1
        docker rm $name    > /dev/null 2>&1
        unlink /var/run/netns/$name  > /dev/null 2>&1
        echo "deleted $name"
        container_index=$((container_index+1))
    done
}

create_all() {
    container_index=0
    mkdir -p /var/run/netns

    while [ $container_index -lt $max_containers ]
    do
        sep="_"
        name="$container_prefix$sep$container_index"
        ifnum=0

        #start docker detached to keep it runing
        #Network will be added later
        #docker run --name $name   -td ubuntu
        docker run --name $name  --network none -td granjan/ubuntu-net-ready /bin/bash
        #pid="$(docker inspect --format '{{.State.Pid}}' $name)"

        echo "## Container name  :" $name
        echo "##           pid   :" $pid

        #steal netns from docker container
        exposedockernetns $name

	   	ifnum=0
    	while [ $ifnum -lt $if_per_container ]
    	do
            ifname="$interface_prefix$container_index$ifnum"
            veth_ifname="veth_$ifname"
            vpp_host_veth_iname="$ifname"

			ip link add name veth_$ifname type veth peer name $vpp_host_veth_iname
			ip link set dev $vpp_host_veth_iname  up
            ip link set $veth_ifname up netns $name

            ip_prefix="24"
            container_veth_ip="$ip_msb.$ifnum.$container_index.2/24"
            #container_veth_network="$ip_msb.$ifnum.$container_index.0/24"
            container_veth_network="$ip_msb.$ifnum.0.0/16"
            container_veth_gw="$ip_msb.$ifnum.$container_index.1"
            vpp_host_veth_ip="$ip_msb.$ifnum.$container_index.1/24"

            #ip netns is implemented over exec so need to to export
	        export name="$name"
		    export veth_ifname="$veth_ifname"
		    export container_veth_ip="$container_veth_ip"
		    export veth_ifname="$veth_ifname"
		    export container_veth_network="$container_veth_network"
		    export container_veth_gw="$container_veth_gw"

		    ip netns exec $name \
            bash -c "
                ip link set dev lo up
                ip link set dev $veth_ifname up
                echo ip link set dev $veth_ifname up
                ip addr add $container_veth_ip dev $veth_ifname
                echo ip addr add $container_veth_ip dev $veth_ifname
                ip route add $container_veth_network via $container_veth_gw dev $veth_ifname
                echo ip route add $container_veth_network via $container_veth_gw dev $veth_ifname
                ip a
                ip route
                             "

            sudo vppctl create host-interface name $vpp_host_veth_iname
            sudo vppctl set int state host-$vpp_host_veth_iname  up
            sudo vppctl set int ip address host-$vpp_host_veth_iname  $vpp_host_veth_ip


            ifnum=$((ifnum+1))
        done
        container_index=$((container_index+1))
    done

}

#Hack
vppctl restart

delete_all
create_all


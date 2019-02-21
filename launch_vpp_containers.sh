#!/bin/bash

if [ -z "$VPP_WS_DIR"  ]
then
    echo "##### \$VPP_WS_DIR is empty."
    echo "##### Please go to the vpp root directory and run below commands."
    echo "   export VPP_WS_DIR=\`pwd\`"
    exit
fi

if [ $USER != "root"  ] ; then
    echo "Restarting script with sudo..."
    sudo VPP_WS_DIR=$VPP_WS_DIR  $0 ${*}
    exit
fi


if_per_container=2
container_prefix="sity"
interface_prefix="sity"
max_containers=2
ip_msb="181"
ip_vxlan_msb="6"
bridge_domain="13"
vxlan_vni="13"
src_volume="$VPP_WS_DIR"
dest_volume="/vpp"
docker_image="granjan/debian-net-ready:v1.0"
#docker_image=Not needed for ubuntu for now

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

    #Required to grab and create network namespace for assigning veth or tap
    mkdir -p /var/run/netns

    while [ $container_index -lt $max_containers ]
    do
        sep="_"
        name="$container_prefix$sep$container_index"
        ifnum=0

        #Network will be added later
        #--previliged is needed for vpp installation it think it can write sysctl
        docker run \
            --privileged --name $name \
            -v $src_volume:$dest_volume  \
            --network none -td \
             $docker_image   /bin/bash

        vpp_script=$(mktemp /tmp/vpp_start.XXXXXXXXXX)
        vpp_startup_conf=$(mktemp /tmp/vpp_startup_conf.XXXXXXXXXX)

        echo "#!/bin/bash
cd /vpp/build-root
dpkg -i *.deb
mkdir  -p /var/log/vpp/
touch /var/log/vpp/vpp.log
/usr/bin/vpp  -c /etc/vpp_startup.conf
#Add a logic to check if vpp is ready
sleep 20
" > $vpp_script
        chmod +x $vpp_script

		docker cp $vpp_script  $name:/vpp_install_start
		rm $vpp_script

        echo "
unix {
  log /var/log/vpp/vpp.log
  full-coredump
  cli-listen /run/vpp/cli.sock
  gid 0
}

cpu {
       main-core 2
}

 plugins {
        plugin default { enable }
        plugin dpdk_plugin.so { disable  }
 }
" > $vpp_startup_conf
		docker cp $vpp_startup_conf  $name:/etc/vpp_startup.conf
		rm $vpp_startup_conf

		docker exec  $name /bin/sh -c "/vpp_install_start"

        #Hack wait until entrypoint is complte
        #seems entrypoint scipt runs parallelly
        #we need to confirm
        #sleep 20

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
            container_veth_network="$ip_msb.$ifnum.0.0/16"
            container_veth_gw="$ip_msb.$ifnum.$container_index.1"
            vpp_host_veth_ip="$ip_msb.$ifnum.$container_index.1/24"

            #ip netns is implemented over exec so need to to export
            # confirm again
        export name="$name"
        export veth_ifname="$veth_ifname"
        export container_veth_ip="$container_veth_ip"
        export veth_ifname="$veth_ifname"
        export container_veth_network="$container_veth_network"
        export container_veth_gw="$container_veth_gw"

        #Attach the newly created veth to the container
        ip netns exec $name \
            bash -c "
                echo \"In the container $name\"
                ip link set dev lo up
                ip link set dev $veth_ifname up
                echo ip link set dev $veth_ifname up
                ip addr add $container_veth_ip dev $veth_ifname
                echo ip addr add $container_veth_ip dev $veth_ifname
                ip route add $container_veth_network via $container_veth_gw dev $veth_ifname
                echo ip route add $container_veth_network via $container_veth_gw dev $veth_ifname
                ip a
                ip route "


            tempfile=$(mktemp /tmp/output.XXXXXXXXXX)
            echo "#!/bin/bash
                /usr/bin/vppctl show version
                /usr/bin/vppctl create host-interface name $veth_ifname
                /usr/bin/vppctl set interface state host-$veth_ifname up
                /usr/bin/vppctl  set interface ip address host-$veth_ifname $container_veth_ip
                /usr/bin/vppctl ip route add $container_veth_network via $container_veth_gw  host-$veth_ifname
                " > $tempfile

            if [ "$ifnum" == "0" ]; then
                #vxlan only on interface 0
                vtep_ip=$ip_vxlan_msb.0.0.25$container_index
                #bridge_domain="$bridge_domain"
                #vxlan_vni="$vxlan_vni"
			    mac_loopback=`printf '00:60:2f:%02x:%02x:%02x\n' $[RANDOM%256] $[RANDOM%256] $icontainer_index`

			    #Bad Hack
			    if [ $container_index -eq 0 ];then
				    tunnel_src_addr=$ip_msb.$ifnum.0.2
				    tunnel_dest_addr=$ip_msb.$ifnum.1.2
			    else
				    tunnel_src_addr=$ip_msb.$ifnum.1.2
				    tunnel_dest_addr=$ip_msb.$ifnum.0.2
			    fi

                echo "

/usr/bin/vppctl create bridge-domain $bridge_domain learn 1 forward 1 uu-flood 1 flood 1 arp-term 0
#need some logic okay for now to hardcode
/usr/bin/vppctl create vxlan tunnel src $tunnel_src_addr dst $tunnel_dest_addr vni $vxlan_vni
/usr/bin/vppctl set interface l2 bridge vxlan_tunnel0 $bridge_domain 1
/usr/bin/vppctl loopback create mac $mac_loopback
/usr/bin/vppctl set interface l2 bridge loop0 $bridge_domain bvi
/usr/bin/vppctl set interface state loop0 up
/usr/bin/vppctl set interface ip table loop0 5
/usr/bin/vppctl set interface ip address loop0 $vtep_ip/16
" >> $tempfile
fi
            chmod 777 $tempfile
            docker cp $tempfile $name:/vpp_int_conf_$ifnum
            docker exec  $name /bin/sh -c "/vpp_int_conf_$ifnum"
            rm $tempfile

            vppctl create host-interface name $vpp_host_veth_iname
            vppctl set int state host-$vpp_host_veth_iname  up
            vppctl set int ip address host-$vpp_host_veth_iname  $vpp_host_veth_ip

            ifnum=$((ifnum+1))
        done
        container_index=$((container_index+1))
    done

}

#Hack
vppctl restart


delete_all

create_all


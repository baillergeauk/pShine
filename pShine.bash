#!/bin/bash

create () {

    local total_mdt total_ost total_vm args tab pcocc_templates_dir
    local -i t
    if [[ ! -f "$1" ]]; then
        echo "File $1 does not exist, please enter a valid configuration file such as example.conf"
        exit 66
    fi

    # loads configuration file
    source "$1"

    total_mdt=$((mds_count * mdt_count)) # overall mdt count
    total_ost=$((oss_count * ost_count)) # overall ost count
    total_vm=$((mds_count + oss_count + client_count)) #overall vm count
    args=""            #future args for pcocc alloc

    # .yaml and cloud-config path (must not change bcs pcocc searches for templates
    # in specific directories)
    templates_dir="${PCOCC_USER_CONF_DIR:-"$HOME"/.pcocc}"/templates.d

    ### Checking the existence of templates_dir ###

    if ! [[ -d "$templates_dir" ]]; then
         mkdir -p "$templates_dir";
    fi

    ### Creating targets ###

    if [[ -d "$diskfolder"/"$fsname" ]]; then
        rm -rf "${diskfolder:?}"/"$fsname"
    fi

    mkdir -p "$diskfolder"/"$fsname"

    truncate -s "$mgt_size" "$diskfolder"/"$fsname"/mgt

    for i in $(seq 0 $((total_mdt-1))); do
        truncate -s "$mdt_size" "$diskfolder"/"$fsname"/mdt"$i"
    done

    for i in $(seq 0 $((total_ost-1))); do
        truncate -s "$ost_size" "$diskfolder"/"$fsname"/ost"$i"
    done

    ### Writing pcocc template conf ###

    ## Base template

    cat > "$templates_dir"/"$fsname".yaml <<EOF
$fsname/$server_image:
    image: '$server_image'
    resource-set : "default"
    description : "pShine template for /$fsname"
    user-data: $templates_dir/$fsname.cloud-config
EOF

    ## Specific template for servers, based on wished configuration ##

    # mds template with mgs on the first one #

    t=0     #needed to keep track of overall mdt number

    for i in $(seq 0 $((mds_count - 1)));do
        cat >> "$templates_dir"/"$fsname".yaml <<EOF

$fsname/mds$i:
    inherits: '$fsname/$server_image'
    persistent-drives:
EOF

        for j in $(seq 0 $((mdt_count - 1)));do
            echo "       - '$diskfolder/$fsname/mdt$t'"
            t+=1
        done >> "$templates_dir"/"$fsname".yaml

        if [[ "$i" -eq 0 ]]; then
            echo "       - '$diskfolder/$fsname/mgt'" >> "$templates_dir"/"$fsname".yaml
        fi
        args+="$fsname/mds$i,"
    done


    # oss template #

    t=0     #same as before but for ost

    for i in $(seq 0 $((oss_count-1))); do
        cat >> "$templates_dir"/"$fsname".yaml <<-EOF

$fsname/oss$i:
    inherits: '$fsname/$server_image'
    persistent-drives:
EOF

        for j in $(seq 0 $((ost_count-1))); do
            echo "       - '$diskfolder/$fsname/ost$t'"
            t+=1
        done >> "$templates_dir"/"$fsname".yaml
        args+="$fsname/oss$i,"
    done


    # client template  #

    cat >> "$templates_dir"/"$fsname".yaml <<-EOF
$fsname/client:
    inherits: '$fsname/$server_image'
    image: '$client_image'
EOF


    # saving number of client to make restart possible with pShineStart

    echo "#client_count:$client_count" >> "$templates_dir"/"$fsname".yaml

    # saving diskfolder to delete disks with pShineDelete

    echo "#diskfolder:$diskfolder" >> "$templates_dir"/"$fsname".yaml


    ### Writing cloud-config ###

    # ssh key to connect as root

    echo -n "#cloud-config
users:
    - name: root
      ssh-authorized-keys:
        -" > "$templates_dir"/"$fsname".cloud-config

    cat "$HOME"/.ssh/id_rsa.pub >> "$templates_dir"/"$fsname".cloud-config

    # preserve_hostname is needed so all the VMs do not keep the same hostname
    # else, shine can not work properly

    cat >> "$templates_dir"/"$fsname".cloud-config <<EOF

preserve_hostname: false

write_files:
    - path: /etc/shine/models/$fsname.lmf
      permissions: '0644'
      content: |
        # The Lustre filesystem name
        fs_name: $fsname
        #Hosts to Lnet NIDs mapping
        nid_map: nodes=vm[0-$((total_vm-1))] nids=vm[0-$((total_vm-1))]@tcp0

        #Default client mount point path
        mount_path: /$fsname
        #Clients definition
        client: node=vm[$((mds_count+oss_count))-$((total_vm-1))]
EOF

    tab=(b c d e f g h i)       # using a list of values for device name
                            # assuming it goes from /dev/vda incrementing last letter to /dev/vdi and beyond, so might not work on all systems
                            # need to put more letters to go for more than 8 targets/vm

    t=0            # keep track of the last mdt device name (last letter) so mgt can take the next one

    for i in $(seq 0 $((mds_count-1))); do

        for j in $(seq 0 $((mdt_count-1))); do
        echo "        mdt: node=vm$i dev=/dev/vd${tab[j]}" >> "$templates_dir"/"$fsname".cloud-config
        t=$((t + 1))
        done
        if [[ "$i" -eq 0 ]]; then
        echo "        mgt: node=vm$i dev=/dev/vd${tab[t]}" >> "$templates_dir"/"$fsname".cloud-config
        fi
    done

    for i in $(seq "$mds_count" $((oss_count+mds_count-1))); do
        for j in $(seq 0 $((ost_count-1))); do
        echo "        ost: node=vm$i dev=/dev/vd${tab[j]}" >> "$templates_dir"/"$fsname".cloud-config
        done
    done

    ## Optional parameters ##

    echo "$options" | sed 's/^/        /g' >> "$templates_dir"/"$fsname".cloud-config

    ### Starting the Cluster ###
    ### with Shine script ###

    local file
    file="$(mktemp --suffix=-"$fsname".bash)"
    trap -- "rm -f '$file'" EXIT

    cat > "$file" <<EOF
#!/bin/bash

pcocc ssh root@vm0 "shine install -m /etc/shine/models/$fsname.lmf && yes | shine format -f $fsname && shine start -f $fsname && shine mount -f $fsname"
exec bash
EOF
    chmod +x "$file"

    pcocc alloc -p "$partition" -c "$core_count" -E "${file}" "$args""$fsname"/client:"$client_count"

}



delete () {

    local templates_dir diskfolder

    if [[ $# -eq 0 ]]; then
        echo "Missing Argument, use "./pShine.bash delete -f fsname" instead"
        exit 64
    fi

    templates_dir=~/.pcocc/templates.d

    if ! [[ -e "$templates_dir/$1.yaml" ]]; then
         echo "$1 does not exist"
         exit 65
    fi

   # diskfolder=$(cat ~/.pcocc/templates.d/"$1".yaml | grep ^#disk | cut -d ':' -f2)

    diskfolder=$(grep ^\#disk ~/.pcocc/templates.d/"$1".yaml | cut -d ':' -f2)

    echo "The following files and folders will be erased :"
    echo "$diskfolder"/"$1"
    echo "$diskfolder"/"$1"/* | tr ' ' '\n'
    echo "$templates_dir"/"$1".* | tr ' ' '\n'

    read -p "Are you sure you want to delete all the listed files ?(y/n)" -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "${diskfolder:?}"/"$1"
        rm -f "$templates_dir"/"$1".*
    fi
}

start () {

    local core="" partition="" fsname="" clients args

    while [[ $# -gt 0 ]]; do
        key="$1"

        case $key in
            -c)
                core="$2"
                shift # past argument
                shift # past value
                ;;
            -p)
                partition="$2"
                shift
                shift
                ;;
            -f)
                fsname="$2"
                shift
                shift
                ;;
            *)
                echo "Invalid argument: $key"
                exit 64
        esac
    done

    if [[ "$core" = "" ]]||[[ "$partition" = "" ]]||[[ "$fsname" = "" ]]; then
         echo "Needed options : -c [numbler of core], -p [partition], -f [filesystem]"
         exit 64
    fi


    client=$(grep ^#client ~/.pcocc/templates.d/"$fsname".yaml | cut -d ':' -f2)

    args=$(grep ^"$fsname" ~/.pcocc/templates.d/"$fsname".yaml | cut -d ':' -f1 | tr '\n' ',' | cut -d ',' -f2-)

    local file
    file="$(mktemp --suffix=-"$fsname".bash)"
    trap -- "rm -f '$file'" EXIT

    cat > "$file" <<EOF
#!/bin/bash

pcocc ssh root@vm0 "shine install -m /etc/shine/models/$fsname.lmf && shine start -f $fsname && shine mount -f $fsname"
exec bash
EOF
    chmod +x "$file"

    pcocc alloc -c "$core" -p "$partition" -E "$file" "$args""$fsname"/client:$((client-1))

}

help() {

    echo "
    Create and launch a pcocc Cluster with a Lustre FS based on a conf file:
        ./pShine create MODEL_FILE

    Start a previously created one with desired pcocc options:
        ./pShine start -c CORE_NUMBER -p PARTITION -f FSNAME

    Delete an entire pcocc Cluster with Lustre FS:
        ./pShine delete FSNAME
"
}

if [[ $# -eq 0 ]]; then
    echo "Missing argument, try ./pShine --help"
    exit 64
fi

arg="$1"

case $arg in
    create)
        shift
        create "$@"
        exit 0
        ;;
    delete)
        shift
        delete "$@"
        exit 0
        ;;
    start)
        shift
        start "$@"
        exit 0
        ;;
    --help)
        help
        exit 0
        ;;
    *)
        echo "Invalid argument: $arg ;      Try ./pShine --help "
        exit 64
        ;;
esac

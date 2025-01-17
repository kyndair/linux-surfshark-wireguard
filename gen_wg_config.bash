#!/bin/bash
set -e

read_config() {
    config_folder=$(dirname $(readlink -f $0))

    wg_keys=${config_folder}/wg.json
    token_file=${config_folder}/token.json
    token_expires=${config_folder}/token_expires.json
    sswg_log=${config_folder}/sswg.log

    baseurl_1="https://api.surfshark.com"
    baseurl_2="https://ux.surfshark.com"
    baseurl_3="https://api.uymgg1.com"
    baseurl_4="https://ux.uymgg1.com"
    urlcount=4

    generic_servers_file=${config_folder}/generic_servers.json
    static_servers_file=${config_folder}/static_servers.json
    obfuscated_servers_file=${config_folder}/obfuscated_servers.json
    double_servers_file=${config_folder}/double_servers.json   

    generate_conf=1
    reset_all=0
    wireguard_down=0
    wireguard_up=0
    switch_conf=0
    check_status=0
    generate_servers=0
    renew_token=0
}

parse_arg() {
    while getopts 'hdgnrsuZ' opt; do
        case "$opt" in
            Z)  reset_all=1         ;;
            c)  check_status=1      ;;
            d)  wireguard_down=1    ;;
            g)  generate_conf=0     ;;
            n)  renew_token=1       ;;
            r)  generate_servers=1  ;;
            s)  switch_conf=1       ;;
            u)  wireguard_up=1      ;;
            ?|h)
            echo "Usage: $(basename $0) [-f]"
            echo "  -c check status of user"
            echo "  -g ignore generating profile files"
            echo "  -d takedown a surfshark wireguard conf setup with this script"
            echo "  -u bring up a surfshark wireguard conf setup with this script"
            echo "  -n renew tokens"
            echo "  -r regenerate the server conf files"
            echo "  -s switch from one surfshark wireguard conf to another"
            echo "  -Z clear settings, keys and server profile files"
            exit 1                  ;;
        esac
    done
    shift "$(($OPTIND -1))"
}

wg_login() { # login and recieve jwt token and renewal token
    echo "Please enter the username/password that you use for the website or offical applications."
    read -p "Username: " username
    read -p "Password: " password
    tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
    http_status=0
    basen=0
    until [ $http_status -eq 200 ]; do
        let basen=$basen+1; baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            echo "Unable to login, check your credentials."
            rm $tmpfile
            exit 2
        fi
        url=$(eval echo \${$baseurl})/v1/auth/login
        data='{"username":"'${username}'","password":"'${password}'"}'
        http_status=$(curl -o $tmpfile -w "%{http_code}" -d "$data" -H 'Content-Type: application/json' -X POST $url)
        echo "Login "$url $http_status
        echo "Login "$url $http_status $(cat $tmpfile) >> $sswg_log
    done
    rm - f $token_file
    echo $(cat $tmpfile | jq '.') >> $token_file
    rm $tmpfile
}

wg_gen_keys() { # generate priavte/public key pair
    echo "generating new keys"
    wg_prv=$(wg genkey)
    wg_pub=$(echo $wg_prv | wg pubkey)
    rm -f $wg_keys
    echo -e "{\n\t\"pub\":\"$wg_pub\",\n\t\"prv\":\"$wg_prv\"\n}" >> $wg_keys
}

wg_register_pub() { # check to see if the public key has been registered and/or there is an unexpired token & run appropriate modules
    if [ ! -f ${token_expires} ] && [ -f ${wg_keys} ]; then
        wg_reg_pubkey
        wg_check_pubkey
    elif [ $(eval echo $(jq '.pubKey' $token_expires)) = $(eval echo $(jq '.pub' $wg_keys)) ] && [ $(eval echo $(jq '.expiresAt' $token_expires)) '<' $(eval echo $(date -Iseconds -u)) ]; then
        wg_token_renwal
        wg_check_pubkey
    elif [ $(eval echo $(jq '.pubKey' $token_expires)) = $(eval echo $(jq '.pub' $wg_keys)) ]; then
        wg_check_pubkey
    else
        rm -f ${token_file} ${wg_keys}
        wg_login
        wg_gen_keys
        wg_reg_pubkey
        wg_check_pubkey
    fi
}

wg_user_status() { # get current status of user
    url=$baseurl_1/v1/server/user
    token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
    user_status=$(curl -H "${token}" -H "Content-Type: application/json" ${url} | jq '.')
    echo "User Status "$url $user_status >> $sswg_log
    if [ $(echo $user_status | jq '.secured') ]; then
        echo "surfshark wireguard is currently on and your IP info is "$(echo $user_status | jq '.ip, .city, .country')
    else
        echo "surfshark wireguard is currently off and your IP info is "$(echo $user_status | jq '.ip, city, .country')
    fi
}

wg_reg_pubkey() { # register the public key using the jwt token 
    basen=1
    error_count=0
    key_reg=start
    until [ -z "${key_reg##*expiresAt*}" ]; do
        baseurl=baseurl_$basen
        url=$(eval echo \${$baseurl})/v1/account/users/public-keys
        data='{"pubKey":'$(jq '.pub' $wg_keys)'}'
        token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
        key_reg=$(curl -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url} | jq '.')
        echo "Registration "$url $key_reg
        echo "Registration "$url $key_reg >> $sswg_log
        let basen=$basen+2
        if [ -n "${key_reg##*expiresAt*}" ] && [ $basen -gt $apiurls ]; then
            if [ -z "${key_reg##*400*}" ]; then
                if [ -z "${key_reg##*Bad Request*}" ]; then
                    echo "Curl post appears to be malformed"
                    exit 2
                fi
            elif [ -z "${key_reg##*401*}" ]; then
                if [ -z "${key_reg##*Expired*}" ] && [ $error_count -eq 0 ]; then
                    wg_token_renwal
                    error_count=1
                    basen=1
                elif [ -z "${key_reg##*Expired*}" ] && [ $error_count -eq 1 ]; then
                    echo "Token is expiring immediately."
                    exit 2
                elif [ -z "${key_reg##*Token not found*}" ]; then
                    echo "Token was not recognised as a token."
                    echo "If it fails repeatedly check your credentials and that a token exists."
                    exit 2
                fi
            else
                echo "Unknown error"
                exit 2
            fi
        fi
    done
    rm -f $token_expires
    echo "${key_reg}" >> $token_expires
    echo "token requires renewing prior to "$(eval echo $(jq '.expiresAt' $token_expires))
}

wg_check_pubkey() { # validates the public key registration process and confirms token expiry
    tmpfile=$(mktemp /tmp/wg-curl-val.XXXXXX)
    http_status=0
    basen=1
    until [ $http_status -eq 200 ]; do
        baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            echo "Public Key was not validated & authorised, please try again."
            echo "If it fails repeatedly check your credentials and that key registration has completed."
            echo $(cat $tmpfile)
            rm $tmpfile
            exit 2
        fi
        url=$(eval echo \${$baseurl})/v1/account/users/public-keys/validate
        data='{"pubKey":'$(jq '.pub' $wg_keys)'}'
        token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
        http_status=$(curl -o $tmpfile -w "%{http_code}" -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url})
        echo "Validation "$url $http_status
        echo "Validation "$url $http_status $(cat $tmpfile | jq '.') >> $sswg_log
        let basen=$basen+2
    done
    if [ $(eval echo $(jq '.expiresAt' $tmpfile)) = $(eval echo $(jq '.expiresAt' $token_expires)) ]; then
        expire_date=$(eval echo $(jq '.expiresAt' $tmpfile))
        now=$(date -Iseconds -u)
        if [ "${now}" '<' "${expire_date}" ]; then
            echo "Current Date & Time  "${now}          # Display Run Date
            echo "Token will Expire at "${expire_date}  # Display Token Expiry
            logger -t SSWG "RUN DATE:${now}   TOKEN EXPIRES ON: ${expire_date}" # Log Status Information (logread -e SSWG)
        fi
    fi
    rm $tmpfile
}

wg_token_renwal() { # use renewal token to generate new tokens
    basen=1
    error_count=0
    key_ren=start
    until [ -z "${key_ren##*renewToken*}" ]; do
        baseurl=baseurl_$basen
        url=$(eval echo \${$baseurl})/v1/auth/renew
        data='{"pubKey":'$(jq '.pub' $wg_keys)'}'
        token="Authorization: Bearer $(eval echo $(jq '.renewToken' $token_file))"
        key_ren=$(curl -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url} | jq '.')
        echo "Renewal "$url $key_ren
        echo "Renewal "$url $key_ren >> $sswg_log
        let basen=$basen+2
        if [ -n "${key_ren##*renewToken*}" ] && [ $basen -gt $apiurls ]; then
            if [ -z "${key_ren##*400*}" ]; then
                if [ -z "${key_ren##*Bad Request*}" ]; then
                    echo "Curl post appears to be malformed"
                    exit 2
                fi
            elif [ -z "${key_ren##*401*}" ]; then
                if [ -z "${key_ren##*Expired*}" ] && [ $error_count -eq 0 ]; then
                    rm -f ${token_file} ${wg_keys} # reset keys and token if renewal fails
                    wg_login
                    wg_gen_keys
                    error_count=1
                    basen=1
                elif [ -z "${key_ren##*Expired*}" ] && [ $error_count -eq 1 ]; then
                    echo "Token is expiring immediately."
                    exit 2
                elif [ -z "${key_ren##*Token not found*}" ]; then
                    echo "Token was not recognised as a token."
                    echo "If it fails repeatedly check your credentials and that a token exists."
                    exit 2
                fi
            else
                echo "Unknown error"
                exit 2
            fi
        fi
    done
    echo "${key_ren}" > $token_file
    echo "token renewed"
}

get_servers() {
    server_type='generic static obfuscated double'
    for server in $server_type; do
        tmpfile=$(mktemp /tmp/wg-curl-ser.XXXXXX)
        http_status=0
        basen=0
        until [ $http_status -eq 200 ]; do
            let basen=$basen+1; baseurl=baseurl_$basen
            if [ $basen -gt $urlcount ]; then
                echo "Unable to download server information."
                rm $tmpfile
                exit 2
            fi
            url=$(eval echo \${$baseurl})/v4/server/clusters/$server?countryCode=
            token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
            http_status=$(curl -o $tmpfile -w "%{http_code}" -H "${token}" -H "Content-Type: application/json" ${url})
            echo $server" servers "$url $http_status
            echo $server" servers "$url $(cat $http_status | jq '.') >> $sswg_log
        done
        server_file="$server""_servers_file"
        server_file=$(eval echo \${$server_file})
        rm -f $server_file
        echo $(cat $tmpfile | jq '.') >> $server_file
        rm $tmpfile
    done
}

gen_client_confs() {
    mkdir -p "${config_folder}/conf"
    rm -f ${config_folder}/conf/*.conf
    servers='generic static' # still need to work on obfuscated & double, they will need separate conf gens
    for server in $servers; do
        postf=".prod.surfshark.com"
        server_hosts="$server""_servers_file"
        server_hosts=$(eval echo \${$server_hosts})
        server_hosts=$(cat $server_hosts)
        server_hosts=$(echo "${server_hosts}" | jq -c '.[] | [.connectionName,.load,.tags,.pubKey]')
        for row in $server_hosts; do
            srv_host="$(echo $row | jq '.[0]')"
            srv_host=$(eval echo $srv_host)

            srv_load="$(echo $row | jq '.[1]')"
            srv_load=$(eval echo $srv_load)

            srv_tags="$(echo $row | jq '.[2]')"
            srv_tags=$(eval echo $srv_tags)

            srv_pub="$(echo $row | jq '.[3]')"
            srv_pub=$(eval echo $srv_pub)

            file_name=${srv_host%$postf}
            file_name=${file_name/'-'/'-'$(printf %03d $srv_load)'-'}
            srv_tags=${srv_tags/'physical'/}
            srv_tags=${srv_tags/'['/}
            srv_tags=${srv_tags/']'/}
            srv_tags=${srv_tags/','/}
            srv_tags=${srv_tags//' '/}
            if [ "$srv_tags" = '' ]; then
				file_name=${server}-${file_name}
            else
				file_name=${server}-${file_name}-${srv_tags}
			fi
			srv_conf_file=${config_folder}/conf${file_name}.conf

            srv_conf="[Interface]\nPrivateKey=$(eval echo $(jq '.prv' $wg_keys))\nAddress=10.14.0.2/8\n\n[Peer]\nPublicKey=o07k/2dsaQkLLSR0dCI/FUd3FLik/F/HBBcOGUkNQGo=\nAllowedIPs=172.16.0.36/32\nEndpoint=wgs.prod.surfshark.com:51820\nPersistentKeepalive=25\n\n[Peer]\nPublicKey=${srv_pub}\nAllowedIPs=0.0.0.0/0\nEndpoint=${srv_host}:51820\nPersistentKeepalive=25\n"
            echo -e "$srv_conf" > $srv_conf_file
        done
        file_removal="$server""_servers_file"
        file_removal=$(eval echo \${$file_removal})
        rm -f $file_removal
    done
}

surfshark_up() {
    if [ -e ${config_folder}/surfshark ]; then
        surfshark_down
    fi

    PS3="Please enter your choice: "
    echo "Please select your preferred server."
    configs="$(ls -A ${config_folder}/conf/)"
    select server in ${configs}; do
        wg-quick up "${config_folder}/conf/${server}"
        cp -f "${config_folder}/conf/${server}" ${config_folder}/surfshark
        break
    done
}

surfshark_down() {
    if [ -e ${config_folder}/surfshark ]; then
        wg_config=$(cat ${config_folder}/surfshark)
        wg-quick down "${wg_config}"
        rm ${config_folder}/surfshark
    else
        echo "wireguard not started from this script, please clear manually"
    fi
}

reset_surfshark() {
    if [ -e ${config_folder}/surfshark ]; then
        surfshark_down
    fi

    echo "Clearing old settings ..."
    rm -fr ${config_folder}/conf
    rm -f ${config_folder}/*servers.json
    rm -f ${config_folder}/wg.json
    rm -f ${config_folder}/token.json
    rm -f ${config_folder}/token_expires.json
    rm -f ${config_folder}/surfshark
}

read_config
parse_arg "$@"

if [ $reset_all -eq 1 ]; then
    reset_surfshark
    exit 1
fi

if [ $generate_servers -eq 1 ]; then
    get_servers
    gen_client_confs
    echo "server list now:"
    echo "$(ls -xA ${config_folder}/conf/)"
    exit 1
fi

if [ $switch_conf -eq 1 ]; then
    surfshark_switch
    exit 1
fi

if [ $check_status -eq 1 ]; then
    wg_user_status
    exit 1
fi

if [ $renew_token -eq 1 ]; then
        wg_token_renwal
        wg_check_pubkey
    exit 1
fi

if [ $wireguard_up -eq 1 ]; then
    wg_register_pub
    surfshark_up
    exit 1
fi

if [ $wireguard_down -eq 1 ]; then
    surfshark_down
    exit 1
fi

echo "Logging in if needed ..."
if [ -f "$token_file" ]; then
    echo "login not required ..."
else
    wg_login
fi

echo "Generating keys ..."
if [ -f "$wg_keys" ]; then
    echo "using existent wg keys"
else 
    wg_gen_keys
fi

echo "Registring public key ..."
wg_register_pub

if [ $generate_conf -eq 1 ]; then
    echo "Getting the list of servers ..."
    get_servers

    echo "Generating server profiles ..."
    gen_client_confs
fi

if [ ! -e ${config_folder}/surfshark ]; then
    surfshark_up
fi

echo "Done!"

# Intro

This is a simple script that generates wireguard client config files for surfshark
You just need to `curl` and `jq`.

# How to use
To use this file:
1. copy `config.json.sample` into `config.json`
2. replace `config.json` values with your account values. Normally user your "email" and "password" that you use on your official client on Android, iOS, or web, not specially OpenVpn username and password
3. run `gen_wg_config.sh` or place a link in your run path to be able to call the script as required e.g. `ln -s /etc/config/surfshark/gen_wg_config.sh /usr/bin/surfshark`
4. for the bash version it will then use wg-quick to bring up your preferred surfshark vpn server

The server configuration files are named in the following way:
1. Server type, this can be generic (ordinary server suitable for most people), static, obfuscated & double.
2. Server country in ISO 2 digit format e.g. de for germany us for united states of america
3. Server load, this indicates how busy the server is. In general using the closest is preferable but if another only slightly further away is under a much lighter load it usually means you would do better to use the less used server.
4. Server city, this is a 3 letter city code.
5. Server tags. Unless tagged virtual the servers are physical. The other tag used is P2P indicating servers that fully support P2P usage.

## usage

```shell
Usage: gen_wg_config.sh [-f]
-f forces registeration, ignores validation
-g ignore generating profile files
-C clear keys and profile files before generating new ones
-s switch from one surfshark wireguard conf to another
-d shutdown wireguard
```

The -s & -d switches are only in the bash version (ends .bash) not the ash version (ends .sh) as it makes use of features not present in ash including making use of wg-quick which is a bash script unsuitable for ash. Eventually both scripts should have parity of features.

# Caveats

Please take the following caveats into consideration

## Your private/public key expires

The token will last 7 days so it needs to be regenerated before then.
I recommend setting up a cron job to run once a week during a known slack period, and with `-g` parameter.

## Sometimes registering or validating the public key fails

If you are not able to use the generated config files, there might be a chance that there is an unhandled corner case in one of the functions. Check that wg.json and token.json files have been generated. Review the output, this should show where the script failed. It may be worth trying to force the registration of the public key with the -f switch.

# TODO

- implement auto refresh token
- generate luci configuration

Contributors:
yazdan
ruralroots
kyndair

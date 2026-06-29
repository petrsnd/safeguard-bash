#!/bin/bash

print_usage()
{
    cat <<EOF
USAGE: get-requestable-account.sh [-h]
       get-requestable-account.sh [-v version]
       get-requestable-account.sh [-a appliance] [-t accesstoken] [-v version]

  -h  Show help and exit
  -a  Network address of the appliance
  -t  Safeguard access token
  -v  Web API Version: 4 is default

Get all requestable accounts for the current user via Me/RequestEntitlements.

EOF
    exit 0
}

ScriptDir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ -z "$(which jq 2> /dev/null)" ]; then
    >&2 echo "This script requires jq for parsing and manipulating responses."
    exit 1
fi

Appliance=
AccessToken=
Version=4

. "$ScriptDir/utils/loginfile.sh"

while getopts ":t:a:v:h" opt; do
    case $opt in
    t)
        AccessToken=$OPTARG
        ;;
    a)
        Appliance=$OPTARG
        ;;
    v)
        Version=$OPTARG
        ;;
    h)
        print_usage
        ;;
    esac
done

require_login_args

Response=$($ScriptDir/invoke-safeguard-method.sh -a "$Appliance" -T -v $Version -s core -m GET -U "Me/RequestEntitlements" -N <<<$AccessToken)
Error=$(echo "$Response" | jq .Code 2> /dev/null)
if [ -z "$Error" -o "$Error" = "null" ]; then
    echo "$Response" | jq '[.[] | {
        AssetId: .Asset.Id,
        AssetName: .Asset.Name,
        NetworkAddress: .Asset.NetworkAddress,
        PlatformDisplayName: .Asset.PlatformDisplayName,
        AccountId: .Account.Id,
        AccountDomainName: .Account.DomainName,
        AccountName: .Account.Name,
        AccessRequestType: .Policy.AccessRequestProperties.AccessRequestType
    }]'
else
    echo "$Response" | jq .
    exit 1
fi

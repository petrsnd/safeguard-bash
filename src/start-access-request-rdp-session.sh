#!/bin/bash

print_usage()
{
    cat <<EOF
USAGE: start-access-request-rdp-session.sh [-h]
       start-access-request-rdp-session.sh [-v version] [-i requestid] [-x rdpclient] [-k]
       start-access-request-rdp-session.sh [-a appliance] [-B cabundle] [-t accesstoken] [-v version] [-i requestid] [-x rdpclient] [-k]

  -h  Show help and exit
  -a  Network address of the appliance
  -B  CA bundle for SSL validation
  -t  Safeguard access token
  -v  Web API Version: 4 is default
  -i  Request ID
  -x  RDP client executable (default: xfreerdp)
  -k  Skip RDP TLS certificate verification (adds /cert:ignore for xfreerdp variants)

Start an RDP session for an access request via the Web API.

The RDP client must accept a positional .rdp file argument (xfreerdp, xfreerdp3,
and most FreeRDP-based CLI clients do). The client must support SPS in-band
destination selection via the username field. Remmina is known NOT to work.

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
CABundle=
CABundleArg=
Version=4
RequestId=
RdpClient=
IgnoreRdpCert=false

. "$ScriptDir/utils/loginfile.sh"

require_args()
{
    require_login_args
    if [ -z "$RequestId" ]; then
        read -p "Request ID: " RequestId
    fi
}

while getopts ":t:a:B:v:i:x:kh" opt; do
    case $opt in
    t)
        AccessToken=$OPTARG
        ;;
    a)
        Appliance=$OPTARG
        ;;
    B)
        CABundle=$OPTARG
        ;;
    v)
        Version=$OPTARG
        ;;
    i)
        RequestId=$OPTARG
        ;;
    x)
        RdpClient=$OPTARG
        ;;
    k)
        IgnoreRdpCert=true
        ;;
    h)
        print_usage
        ;;
    esac
done

require_args

# Resolve and validate RDP client
RdpClient=${RdpClient:-xfreerdp}
if ! command -v -- "$RdpClient" >/dev/null 2>&1; then
    >&2 echo "RDP client '$RdpClient' not found in PATH."
    exit 1
fi

# Reject remmina — not yet implemented (remmina mangles SPS in-band destination
# selection username; needs a workaround to preserve the '%' field delimiters)
ClientBasename=$(basename "$RdpClient")
if [ "$ClientBasename" = "remmina" ]; then
    >&2 echo "Remmina is not yet supported. Use xfreerdp or xfreerdp3."
    exit 1
fi

# Create secure temp file BEFORE calling InitializeSession
OldUmask=$(umask)
umask 0077
TempRdpFile=$(mktemp "${TMPDIR:-/tmp}/safeguard-rdp.XXXXXX.rdp") || {
    >&2 echo "Failed to create temp file."
    exit 1
}
umask "$OldUmask"
chmod 600 "$TempRdpFile"

trap 'rm -f "$TempRdpFile"' EXIT INT TERM HUP

# Build CA bundle args for invoke calls
InvokeCAArgs=()
if [ ! -z "$CABundle" ]; then
    InvokeCAArgs=(-B "$CABundle")
fi

# GET the access request — diagnostic state check
Result=$($ScriptDir/invoke-safeguard-method.sh -a "$Appliance" "${InvokeCAArgs[@]}" -T -v $Version -s core -m GET -U "AccessRequests/$RequestId" -N <<<$AccessToken)
if [ $? -ne 0 ]; then
    >&2 echo "Failed to query access request $RequestId."
    echo "$Result"
    exit 1
fi
Error=$(echo "$Result" | jq .Code 2>/dev/null)
if [ ! -z "$Error" ] && [ "$Error" != "null" ]; then
    >&2 echo "Error retrieving access request $RequestId:"
    echo "$Result" | jq .
    exit 1
fi

Type=$(echo "$Result" | jq --raw-output '.AccessRequestType')
LType=$(echo "$Type" | tr '[:upper:]' '[:lower:]')
case $LType in
remotedesktop)
    ;;
*)
    >&2 echo "Unable to launch RDP session for access request type '$Type'."
    >&2 echo "This script only supports RemoteDesktop requests (not RemoteDesktopApplication)."
    exit 1
    ;;
esac

State=$(echo "$Result" | jq --raw-output '.State')
if [ "$State" != "RequestAvailable" ]; then
    >&2 echo "Warning: Access request state is '$State' (expected 'RequestAvailable')."
    >&2 echo "Attempting InitializeSession anyway — the API response is authoritative."
fi

# POST InitializeSession
Result=$($ScriptDir/invoke-safeguard-method.sh -a "$Appliance" "${InvokeCAArgs[@]}" -T -v $Version -s core -m POST -U "AccessRequests/$RequestId/InitializeSession" -N <<<$AccessToken)
if [ $? -ne 0 ]; then
    >&2 echo "InitializeSession call failed for request $RequestId."
    echo "$Result"
    exit 1
fi
Error=$(echo "$Result" | jq .Code 2>/dev/null)
if [ ! -z "$Error" ] && [ "$Error" != "null" ]; then
    >&2 echo "InitializeSession returned an error:"
    echo "$Result" | jq .
    exit 1
fi

# Extract RDP connection file content
RdpContent=$(echo "$Result" | jq --raw-output '.RdpConnectionFile')
if [ -z "$RdpContent" ] || [ "$RdpContent" = "null" ]; then
    >&2 echo "InitializeSession did not return an RdpConnectionFile."
    >&2 echo "Response:"
    echo "$Result" | jq .
    exit 1
fi

# Write .rdp content to temp file
printf '%s' "$RdpContent" > "$TempRdpFile"
if [ $? -ne 0 ]; then
    >&2 echo "Failed to write RDP file to $TempRdpFile."
    exit 1
fi

# Launch RDP client
>&2 echo "Opening RDP connection..."
RdpArgs=("$TempRdpFile")
if [ "$IgnoreRdpCert" = "true" ]; then
    case $ClientBasename in
    xfreerdp|xfreerdp3)
        RdpArgs+=("/cert:ignore")
        ;;
    esac
fi
case $ClientBasename in
xfreerdp3)
    RdpArgs+=("/p:" "/d:")
    ;;
esac
"$RdpClient" "${RdpArgs[@]}"
RdpExit=$?
exit "$RdpExit"

spinner() { local pid=$1; local delay=0.1; while kill -0 $pid 2>/dev/null; do printf "."; sleep $delay; done; echo; }
readInput() { read -rp "$1: " REPLY; echo "$REPLY"; }
initialCheck() { [[ $EUID -ne 0 ]] && echo "Run as root" && exit 1; }

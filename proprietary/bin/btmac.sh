#!/system/bin/sh

# Read BT MAC address from idme and convert to long form (adding colons) then set it to system property
if [ -f /proc/idme/bt_mac_addr ]; then
    bt_mac_idme=`cat /proc/idme/bt_mac_addr`
    bt_mac=${bt_mac_idme:0:2}:${bt_mac_idme:2:2}:${bt_mac_idme:4:2}:${bt_mac_idme:6:2}:${bt_mac_idme:8:2}:${bt_mac_idme:10:2}
    setprop persist.service.bdroid.bdaddr ${bt_mac}
    bt_mac_prop=`getprop persist.service.bdroid.bdaddr`
    echo "BT MAC:" ${bt_mac_prop}
else
    echo "BT MAC: is not set in idme!"
fi

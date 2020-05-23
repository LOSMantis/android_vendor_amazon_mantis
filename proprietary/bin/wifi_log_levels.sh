#!/system/bin/sh
## Copyright (c) 2017 - 2019 Amazon.com, Inc. or its affiliates.  All rights reserved.
##
## PROPRIETARY/CONFIDENTIAL.  USE IS SUBJECT TO LICENSE TERMS.

LOGSRC="wifi"
LOGNAME="wifi_log_levels"
METRICSTAG="metrics.$LOGNAME"
LOGCATTAG="main.$LOGNAME"
DELAY=110 # every 2 minutes including 10 seconds for traffic_report and noise histogram
INTERVAL=10
LOOPSTILMETRICS=29 # Should send to metrics buffer every hour
DEFAULT_RSSI_THD="-75,-71,-68,-61"
currentLoop=0
IWPRIV=/system/bin/iwpriv
IFCONFIG=/system/bin/ifconfig
IP=/system/bin/ip
IW=/system/bin/iw
TOOLBOX=/system/bin/toolbox
noise_array=( -55 -57 -62 -67 -72 -77 -81 -84 -87 -90 -92 )
WLANINTF="Down"
CHIPNSS="2"
PREVIOUS_NOISEBAR=0
PREVIOUS_INTERFACE=""

if [ ! -x $IWPRIV ] ; then
    exit
fi

if [ ! -x $IW ] ; then
    exit
fi

function set_wlan_interface ()
{
    WLAN_INTERFACE=`getprop wifi.interface`
    WLAN_INTERFACE_UP=`ifconfig | grep wlan`
    WLAN_STATUS=`$IW $WLAN_INTERFACE link | head -n1 | cut -d " " -f1`
    P2P_INTERFACE=`$IFCONFIG |grep p2p- |cut -d " " -f1`
    P2P_STATUS=`$IW $P2P_INTERFACE link | head -n1 | cut -d " " -f1`

    ## disable this check and use wlan0 for all stats (except ifconfig) until proper p2p stats were available
#    # check wlan and p2p connection status to decide which interface to get stats
#    if [[ ( "$WLAN_STATUS" != "Connected" ) && ( "$P2P_STATUS" = "Connected" ) ]]; then
#        WLAN_INTERFACE=$P2P_INTERFACE
#    fi
}

function iwpriv_conn_status ()
{
    IFS=$'\t\n'
    CONN_STATUS=`$IW $WLAN_INTERFACE link | head -n1 | cut -d " " -f1`
    unset IFS
}

function iwpriv_traffic_noise_report ()
{
    IFS=$'\t\n'

    # disable power saving mode
    $IWPRIV $WLAN_INTERFACE driver "SET_CHIP KeepFullPwr 1" > /dev/null

    # enable noise histogram collection
    $IWPRIV $WLAN_INTERFACE driver "noise_histogram enable" > /dev/null
#        $IWPRIV $WLAN_INTERFACE driver "noise_histogram reset" > /dev/null

    # enable traffic report
    $IWPRIV $WLAN_INTERFACE driver "traffic_report enable"  > /dev/null
#        $IWPRIV $WLAN_INTERFACE driver "traffic_report reset" > /dev/null

    # wait for $INTERVAL seconds to collect result
    sleep $INTERVAL
    TRAFFIC_REPORT=($($IWPRIV $WLAN_INTERFACE driver "traffic_report get"))

    # disable traffic report
    $IWPRIV $WLAN_INTERFACE driver "traffic_report disable" > /dev/null

    # collect noise histogram
    if [ $CHIPNSS = "2" ]; then
        NOISE_HISTOGRAM=($($IWPRIV $WLAN_INTERFACE driver "noise_histogram get2"))
    else
        NOISE_HISTOGRAM=($($IWPRIV $WLAN_INTERFACE driver "noise_histogram get"))
    fi

    # disable noise histogram collection
    $IWPRIV $WLAN_INTERFACE driver "noise_histogram disable" > /dev/null

    # restore power saving mode from Android
    $IWPRIV $WLAN_INTERFACE driver "SET_CHIP KeepFullPwr 0" > /dev/null

    ((j=0))
    ((WF1_NOISE_FLAG=0))
    for line in ${NOISE_HISTOGRAM[@]}; do
        if [ $CHIPNSS = "2" ]; then
            if [ $line = *"WF1"* ]; then
                ((WF1_NOISE_FLAG=1))
            fi
        fi

        if [[ $line = *"Power"* ]]; then
            if [ $j -gt 10 ]; then
                NOISE_FLOOR2[$j-11]=${line##* }
            else
                NOISE_FLOOR[$j]=${line##* }
            fi
            ((j = j + 1))
        fi
    done

    for line in ${TRAFFIC_REPORT[@]}; do
        case $line in
            "CCK false"*)
                    CCK_ERR=${line#*: }
                    ;;
            "OFDM false"*)
                    OFDM_ERR=${line#*: }
                    ;;
            "CCK Sig"*)
                    CCK_CRC=${line#*: }
                    ;;
            "OFDM Sig"*)
                    OFDM_CRC=${line#*: }
                    ;;
            "Total packet transmitted"*)
                    TX_TOTAL=${line#*: }
                    ;;
            "Total tx ok packet"*)
                    TX_OK=${line#*: }
                    ;;
            "Total tx failed packet"*)
                    TX_FAIL=${line#*: }
                    ;;
            "Total tx retried packet"*)
                    TX_RETRY=${line#*: }
                    ;;
            "Total rx mpdu"*)
                    RX_OK=${line#*: }
                    ;;
            "Total rx fcs"*)
                    RX_FCS=${line#*: }
                    ;;
            "ch_busy"*)
                    CH_BUSY=${line#*ch_busy }
                    CH_BUSY=${CH_BUSY%% us*}
                    CH_IDLE=${line#*ch_idle }
                    CH_IDLE=${CH_IDLE%% us*}
                    CH_TOTAL=${line#*total_period }
                    CH_TOTAL=${CH_TOTAL%% us*}
                    ;;
            "my_data_rx_time"*)
                    RX_TIME=${line#*: }
                    RX_TIME=${RX_TIME%% us*}
                    RX_PERCENT=${line##*: }
                    ;;
            "my_tx_time"*)
                    TX_TIME=${line#* }
                    TX_TIME=${TX_TIME%% us*}
                    TX_PERCENT=${line##*: }
                    ;;
        esac
    done
    unset IFS
}

function ifconfig_kernel_stat ()
{
    ETHERNET=`$IFCONFIG eth0 | grep "inet "`
    IFS=$'\t\n'

    # select either wlan0 or p2p interface for ifconfig stat
    if [ -z "$ETHERNET" ]; then
        if [[ ( "$WLAN_STATUS" != "Connected" ) && ( "$P2P_STATUS" = "Connected" ) ]]; then
            STAT=($($IFCONFIG $P2P_INTERFACE))
        else
            STAT=($($IFCONFIG $WLAN_INTERFACE))
        fi
    else
        STAT=($($IFCONFIG eth0))
    fi
    for line in ${STAT[@]}; do
        echo $line
        case $line in
            *"RX packets"*)
                    RXPACKETS=`echo $line | cut -d ":" -f2 | cut -d " " -f1`
                    RXERRORS=`echo $line | cut -d ":" -f3 | cut -d " " -f1`
                    RXDROPPED=`echo $line | cut -d ":" -f4 | cut -d " " -f1`
                    ;;
            *"TX packets"*)
                    TXPACKETS=`echo $line | cut -d ":" -f2 | cut -d " " -f1`
                    TXERRORS=`echo $line | cut -d ":" -f3 | cut -d " " -f1`
                    TXDROPPED=`echo $line | cut -d ":" -f4 | cut -d " " -f1`
                    ;;
            *"bytes"*)
                    RXBYTES=`echo $line | cut -d ":" -f2 | cut -d " " -f1`
                    TXBYTES=`echo $line | cut -d ":" -f3 | cut -d " " -f1`
                    ;;
        esac
    done
    unset IFS
}

function arp_check ()
{
    ##check if gateway address is valid in arp table
    ETHERNET=`$IP addr show dev eth0 | grep "inet "`
    ## first check if Ethernet is used
    if [ -z "$ETHERNET" ]; then
        IFACE=$WLAN_INTERFACE
    else
        IFACE=eth0
    fi
    GATEWAY=`$IP route get 8.8.8.8 | grep $IFACE | cut -d " " -f3`
    if [[ $GATEWAY = *[:blank:]* ]]; then
        arp_flag="no_gateway"
        return
    fi
    ARP_OUTPUT=`$IP neigh show dev $IFACE | grep $GATEWAY`
    ARP_FLAG=${ARP_OUTPUT##* }
    if [ -z "$ARP_FLAG" ]; then
        arp_flag="$IFACE arp=no_entry"
    else
        arp_flag="$IFACE arp=$ARP_FLAG"
    fi
}

function iwpriv_stat_tokens ()
{
    IFS=$'\t\n'
    STAT=($($IWPRIV $WLAN_INTERFACE driver stat))

    for line in ${STAT[@]}; do
        case $line in
            "Tx Total cnt"*)
                TXFRAMES=${line#*= }
                ;;
            "Tx Fail Cnt"*)
                TXFAIL=${line#*= }
                ;;
            "RX Success"*)
                RXFRAMES=${line#*= }
                ;;
            "RX with CRC"*)
                RXCRC=${line#*= }
                RXCRC=${RXCRC%%,*}
                RXPER=${line#*PER = }
                RXPER=${RXPER%%,*}
                ;;
            "RX drop FIFO full"*)
                RXDROP=${line#*= }
                ;;
            "RateTable"*)
                PHYMODE=${line#*= }
                PHYMODE=${PHYMODE%%_*}
                ;;
            "Beacon RSSI"*)
                BEACONRSSI=${line#*= }
                ;;
            "NOISE"*)
                NOISE=${line#*= }
                ;;
            "LinkSpeed"*)
                PHYRATE=${line#*= }
                ;;
            "AR TX Rate"*)
                ARTXRATE=${line#*= }
                ;;
            "Last TX Rate"*)
                TXRATE=${line#*= }
                STRING=${TXRATE#*,}
                RATE1=${TXRATE%,"$STRING"}
                RATE1+="_"
                SUBSTRING=${STRING#*,}
                BW1=`echo ${STRING%,"$SUBSTRING"} | cut -d " " -f2`
                LASTTXRATE=$RATE1$BW1
                ;;
            "Chip Out TX Power"*)
                LASTTXPOWER=${line#*= }
                ;;
            "Last RX Rate"*)
                RXRATE=${line#*= }
                STRING=${RXRATE#*,}
                RATE1=${RXRATE%,"$STRING"}
                RATE1+="_"
                SUBSTRING=${STRING#*,}
                BW1=`echo ${STRING%,"$SUBSTRING"} | cut -d " " -f2`
                LASTRXRATE=$RATE1$BW1
                ;;
            "Last RX Data RSSI"*)
                RSSI=${line#*= }
                ;;
            "DBDC0"*)
                TXAGG=${line#*: }
                ;;
        esac
    done

    unset IFS
}

function get_max_signal_stats
{
    maxNoise=0
    maxNoise2=0
    maxSnr=0

    maxRssi=$BEACONRSSI
    dataRssi=${RSSI% *}

    # update RSSI property
    setprop 'wifi.ro.wlan0.rssi' $maxRssi

    #skip >57 dBm for now
    NOISE_FLOOR[0]=0
    NOISE_FLOOR[1]=0
    ((j=0))
    ((maxN=0))
    maxIndex=0
    for n in ${NOISE_FLOOR[@]}; do
        if (( n >= maxN )); then
            maxN=$n
            maxIndex=$j
        fi
        ((j = j + 1))
    done
    maxNoise=(`echo ${noise_array[$maxIndex]}`)

    # update noise property
    setprop 'wifi.ro.wlan0.noise' $maxNoise

    if [ $CHIPNSS = "2" ]; then # second chain
        dataRssi2=${RSSI#* }
        NOISE_FLOOR2[0]=0
        NOISE_FLOOR2[1]=0
        ((j=0))
        ((maxN=0))
        maxIndex=0
        for n in ${NOISE_FLOOR2[@]}; do
            if (( n >= maxN )); then
                maxN=$n
                maxIndex=$j
            fi
            ((j = j + 1))
        done
    fi

    if [ WF1_NOISE_FLAG == 1 ]; then
        maxNoise2=(`echo ${noise_array[$maxIndex]}`)
    else
        maxNoise2=$maxNoise
    fi

    if (( maxRssi != 0 && maxNoise != 0 )); then
        maxSnr=$(($maxRssi - $maxNoise))
    fi
}

function iwpriv_show_channel
{
    CHANNEL=`$IWPRIV $WLAN_INTERFACE driver get_cnm | grep channels | cut -d " " -f4`
}

function log_metrics_phymode
{
    if [ "$PHYMODE" ] ; then
        mode=${PHYMODE}
        logStr="$LOGSRC:$LOGNAME:WifiMode$mode=1;CT;1:NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr

        BANDWIDTH=${ARTXRATE#*BW}
        BANDWIDTH=${BANDWIDTH%%,*}"MHz"
        logStr="$LOGSRC:$LOGNAME:ChannelBandwidth$BANDWIDTH=1;CT;1:NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
    fi
}

function log_metrics_rssi
{
    # dev rssi
    if [ "$maxRssi" -eq 0 ]; then
        return 0
    fi
    logStr="$LOGSRC:$LOGNAME:RssiLevel$maxRssi=1;CT;1:NR"
    $TOOLBOX log -m -t $METRICSTAG $logStr
}

function log_metrics_snr
{
    # dev snr
    if [ "$maxSnr" -eq 0 ]; then
        return 0
    fi
    logStr="$LOGSRC:$LOGNAME:SnrLevel$maxSnr=1;CT;1:NR"
    $TOOLBOX log -m -t $METRICSTAG $logStr
}


function log_metrics_noise
{
    # dev noise
    if [ "$maxNoise" -eq 0 ]; then
        return 0
    fi
    logStr="$LOGSRC:$LOGNAME:NoiseLevel$maxNoise=1;CT;1:NR"
    $TOOLBOX log -m -t $METRICSTAG $logStr
}


function log_metrics_mcs
{
    #dev mcs
    mcs=${LASTRXRATE/,*/}
    if [ "$mcs" ] ; then
        logStr="$LOGSRC:$LOGNAME:$mcs=1;CT;1:NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
    fi
}


function log_connstatus_metrics
{
    if [[ $CONN_STATUS = "Connected" ]]; then
        logStr="$LOGSRC:$LOGNAME:ConnStatusConnected=1;CT;1;NR"
    else
        logStr="$LOGSRC:$LOGNAME:ConnStatusDisconnected=1;CT;1;NR"
    fi
    $TOOLBOX log -m -t $METRICSTAG $logStr
}

function log_metrics_chnstat
{
    if (( CH_TOTAL != 0 )); then
        logStr="$LOGSRC:$LOGNAME:ChanBusy$ChanBusy=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
        logStr="$LOGSRC:$LOGNAME:ChanTx$ChanTx=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
        logStr="$LOGSRC:$LOGNAME:ChanRx$ChanRx=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
    fi

    if (( TX_TOTAL != 0 )); then
        logStr="$LOGSRC:$LOGNAME:TxGood$TxGood=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
        logStr="$LOGSRC:$LOGNAME:TxBad$TxBad=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
        logStr="$LOGSRC:$LOGNAME:TxRetry$TxRetry=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
    fi

    if (( RX_OK != 0 )); then
        logStr="$LOGSRC:$LOGNAME:RxGood$RxGood=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
        logStr="$LOGSRC:$LOGNAME:RxBad$RxBad=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
    fi
}

function kdm_rssi_level()
{
    if [[ "$1" -lt "${RSSITHD[0]}" ]]; then
        RSSIBAR=0
    elif [[ "$1" -lt "${RSSITHD[1]}" ]]; then
        RSSIBAR=1
    elif [[ "$1" -lt "${RSSITHD[2]}" ]]; then
        RSSIBAR=2
    elif [[ "$1" -lt "${RSSITHD[3]}" ]]; then
        RSSIBAR=3
    elif [[ "$1" -lt "-40" ]]; then
        RSSIBAR=4
    elif [[ "$1" -lt "-20" ]]; then
        RSSIBAR=5
    else
        RSSIBAR=6
    fi
}

function log_kdm_rssi_level
{

    #get bandwidth
    if [ ! "$BANDWIDTH" ] ; then
        # Device is 11a/b/g which only has 20 MHz bandwidth
        BANDWIDTH="20MHz"
    fi

    kdm_rssi_level ${maxRssi}
    beacon_rssibar=$RSSIBAR

    kdm_rssi_level ${dataRssi}
    rssibar=$RSSIBAR

    ## Dual-chain metrics are only enabled on Mantis
    if [ $CHIPNSS = "2" ]; then
        kdm_rssi_level ${dataRssi2}
        rssibar2=$RSSIBAR
        logStr="wifiKDM:RSSILevel:fgtracking=false;DV;1,Counter=1;CT;1,unit=count;DV;1,metadata=!{\"d\"#{\"metadata3\"#\"Data\"$\"metadata2\"#\"${BANDWIDTH}\"$\"metadata1\"#\"${rssibar2} bar\"$\"metadata\"#\"${rssibar} bar\"$\"key\"#\"${CHANNEL}\"}};DV;1:NR"
    else
        logStr="wifiKDM:RSSILevel:fgtracking=false;DV;1,Counter=1;CT;1,unit=count;DV;1,metadata=!{\"d\"#{\"metadata3\"#\"Data\"$\"metadata2\"#\"${BANDWIDTH}\"$\"metadata\"#\"${rssibar} bar\"$\"key\"#\"${CHANNEL}\"}};DV;1:NR"
    fi
    $TOOLBOX log -v -t "Vlog" $logStr

    logStr="wifiKDM:RSSILevel:fgtracking=false;DV;1,Counter=1;CT;1,unit=count;DV;1,metadata=!{\"d\"#{\"metadata3\"#\"Beacon\"$\"metadata2\"#\"${BANDWIDTH}\"$\"metadata\"#\"${beacon_rssibar} bar\"$\"key\"#\"${CHANNEL}\"}};DV;1:NR"
    $TOOLBOX log -v -t "Vlog" $logStr
}


function kdm_noise_level()
{
    if [[ "$1" -lt "${RSSITHD[0]}" ]]; then
        NOISEBAR=0
    elif [[ "$1" -lt "${RSSITHD[1]}" ]]; then
        NOISEBAR=1
    elif [[ "$1" -lt "${RSSITHD[2]}" ]]; then
        NOISEBAR=2
    elif [[ "$1" -lt "${RSSITHD[3]}" ]]; then
        NOISEBAR=3
    elif [[ "$1" -lt "-40" ]]; then
        NOISEBAR=4
    elif [[ "$1" -lt "-20" ]]; then
        NOISEBAR=5
    else
        NOISEBAR=$PREVIOUS_NOISEBAR
    fi
    PREVIOUS_NOISEBAR=$NOISEBAR
}

function log_kdm_noise_level
{
    kdm_noise_level ${maxNoise}
    noisebar=$NOISEBAR
    TVStatus="Unknown"
    CoexFlag="Unknown"
    ## Dual-chain metrics are only enabled on Mantis
    if [ $CHIPNSS = "2" ]; then
        kdm_noise_level ${maxNoise2}
        noisebar2=$NOISEBAR
        logStr="wifiKDM:NoiseLevel:fgtracking=false;DV;1,Counter=1;CT;1,unit=count;DV;1,metadata=!{\"d\"#{\"metadata3\"#\"${CoexFlag}\"$\"metadata2\"#\"${TVStatus}\"$\"metadata1\"#\"${noisebar2} bar\"$\"metadata\"#\"${noisebar} bar\"$\"key\"#\"${CHANNEL}\"}};DV;1:NR"
    else
        logStr="wifiKDM:NoiseLevel:fgtracking=false;DV;1,Counter=1;CT;1,unit=count;DV;1,metadata=!{\"d\"#{\"metadata\"#\"${noisebar} bar\"$\"key\"#\"${CHANNEL}\"}};DV;1:NR"
    fi
    $TOOLBOX log -v -t "Vlog" $logStr
}

function kdm_snr_level()
{
    if [[ "$1" -lt "5" ]]; then
        SNRBAR=0
    elif [[ "$1" -lt "10" ]]; then
        SNRBAR=1
    elif [[ "$1" -lt "15" ]]; then
        SNRBAR=2
    elif [[ "$1" -lt "20" ]]; then
        SNRBAR=3
    elif [[ "$1" -lt "25" ]]; then
        SNRBAR=4
    elif [[ "$1" -lt "30" ]]; then
        SNRBAR=5
    else
        SNRBAR=6
    fi
}

function log_kdm_snr_level
{
    #dev mcs
    mcs=${LASTRXRATE/,*/}

    snr=$(($rssi - $maxNoise))
    kdm_snr_level ${snr}
    snrbar=$SNRBAR

    ## Dual-chain metrics are only enabled on Mantis
    if [ $CHIPNSS = "2" ]; then
        snr=$(($rssi2 - $maxNoise2))
        kdm_snr_level ${snr}
        snrbar2=$SNRBAR
        logStr="wifiKDM:SNRLevel:fgtracking=false;DV;1,Counter=1;CT;1,unit=count;DV;1,metadata=!{\"d\"#{\"metadata3\"#\"${snrbar2} bar\"$\"metadata2\"#\"${mcs}\"$\"metadata1\"#\"${rssibar} bar\"$\"metadata\"#\"${snrbar} bar\"$\"key\"#\"${CHANNEL}\"}};DV;1:NR"
    else
        logStr="wifiKDM:SNRLevel:fgtracking=false;DV;1,Counter=1;CT;1,unit=count;DV;1,metadata=!{\"d\"#{\"metadata2\"#\"${mcs}\"$\"metadata1\"#\"${snrbar} bar\"$\"metadata\"#\"${rssibar} bar\"$\"key\"#\"${CHANNEL}\"}};DV;1:NR"
    fi
    $TOOLBOX log -v -t "Vlog" $logStr
}

function log_kdm_band
{

    #get bandwidth
    if [ ! "$BANDWIDTH" ] ; then
        # Device is 11a/b/g which only has 20 MHz bandwidth
        BANDWIDTH="20MHz"
    fi

    if [[ "$PHYMODE" == "AC" ]] ; then
        wifimode="11ac"
    elif [[ "$PHYMODE" == "G" ]] ; then
        wifimode="11g"
    elif [[ "$PHYMODE" == "A" ]] ; then
        wifimode="11a"
    elif [[ "$PHYMODE" == "B" ]] ; then
        wifimode="11b"
    else
        wifimode="11n"
    fi

    logStr="wifiKDM:Band:fgtracking=false;DV;1,Counter=1;CT;1,unit=count;DV;1,metadata=!{\"d\"#{\"metadata1\"#\"${wifimode}\"$\"metadata\"#\"${BANDWIDTH}\"$\"key\"#\"${CHANNEL}\"}};DV;1:NR"
    $TOOLBOX log -v -t "Vlog" $logStr
}

function log_kdm_phyrate
{
    logStr="wifiKDM:PhyRate:fgtracking=false;DV;1,Counter=1;CT;1,unit=count;DV;1,metadata=!{\"d\"#{\"metadata3\"#\"${wifimode}\"$\"metadata2\"#\"${snrbar} bar\"$\"metadata1\"#\"${rssibar} bar\"$\"metadata\"#\"${LASTTXRATE}\"$\"key\"#\"Tx\"}};DV;1:NR"
    $TOOLBOX log -v -t "Vlog" $logStr
    logStr="wifiKDM:PhyRate:fgtracking=false;DV;1,Counter=1;CT;1,unit=count;DV;1,metadata=!{\"d\"#{\"metadata3\"#\"${wifimode}\"$\"metadata2\"#\"${snrbar} bar\"$\"metadata1\"#\"${rssibar} bar\"$\"metadata\"#\"${LASTRXRATE}\"$\"key\"#\"Rx\"}};DV;1:NR"
    $TOOLBOX log -v -t "Vlog" $logStr
}

function log_kdm_txop
{
    TVStatus="Unknown"
    logStr="wifiKDM:Txop:fgtracking=false;DV;1,Counter=1;CT;1,unit=count;DV;1,metadata=!{\"d\"#{\"metadata2\"#\"${rssibar} bar\"$\"metadata1\"#\"${TVStatus}\"$\"metadata\"#\"${TXOPSCALE}\"$\"key\"#\"${CHANNEL}\"}};DV;1:NR"
    $TOOLBOX log -v -t "Vlog" $logStr
}

function log_wifi_metrics
{
    log_metrics_rssi
    log_metrics_snr
    log_metrics_noise
    log_metrics_mcs
    log_metrics_phymode
    log_metrics_chnstat

    log_kdm_rssi_level
    log_kdm_noise_level
    log_kdm_snr_level
    log_kdm_band
    log_kdm_phyrate
    log_kdm_txop
}

function log_logcat
{
    TXPER=0
    if [[ ${TXFRAMES} -ne 0 ]] ; then
        TXPER=$((${TXFAIL} * 100 / (${TXFRAMES} + ${TXFAIL})))
    fi
    if [ $CHIPNSS = "2" ]; then
        logStr="$LOGNAME:$WLAN_INTERFACE:rssi=$dataRssi;rssi2=$dataRssi2;noise=$maxNoise;noise2=$maxNoise2;channel=$CHANNEL;"
    else
        logStr="$LOGNAME:$WLAN_INTERFACE:rssi=$dataRssi;noise=$maxNoise;channel=$CHANNEL;"
    fi
    logStr=$logStr"txframes=$TXFRAMES;txfails=$TXFAIL;txper=$TXPER%;"
    logStr=$logStr"txaggr=$TXAGG;"
    logStr=$logStr"rxframes=$RXFRAMES;rxcrc=$RXCRC;rxper=$RXPER;rxdrop=$RXDROP;"
    logStr=$logStr"phymode=$PHYMODE;phyrate=$PHYRATE;lasttxrate=$LASTTXRATE;lastrxrate=$LASTRXRATE;"
    log -t $LOGCATTAG $logStr

    log_kernel_stat
    log_maxmin_signals
    log_traffic_report
    log_mcs_per
}

# Log the airtime utilization and short-term TX/RX statstic
function log_traffic_report
{
    ChanBusy=0
    ChanIdle=0
    ChanTx=0
    ChanRx=0
    TxGood=0
    TxBad=0
    TxRetry=0
    RxGood=0
    RxBad=0

    if (( CH_TOTAL != 0 )); then
        ChanBusy=$((100*$CH_BUSY/$CH_TOTAL))
        ChanIdle=$((100-$ChanBusy))
        ChanTx=$((100*$TX_TIME/$CH_TOTAL))
        ChanRx=$((100*$RX_TIME/$CH_TOTAL))

        # update congestion property
        setprop 'wifi.ro.wlan0.congest' $ChanBusy
    fi

    if (( TX_TOTAL != 0 )); then
        TxGood=$((100*$TX_OK/$TX_TOTAL))
        TxBad=$((100-$TxGood))
        TxRetry=$((100*$TX_RETRY/$TX_TOTAL))
    fi

    if (( RX_OK != 0 )); then
        RxGood=$((100*$RX_OK/($RX_OK + $RX_FCS)))
        RxBad=$((100-$RxGood))
    fi

    logStr="$LOGNAME:ch_busy=$ChanBusy%;ch_idle=$ChanIdle%;"
    logStr=$logStr"ch_tx=$ChanTx%;ch_rx=$ChanRx%;"
    logStr=$logStr"tx_ok=$TxGood%;tx_fail=$TxBad%;tx_retry=$TxRetry%;rx_ok=$RxGood%;rx_fcs=$RxBad%;"
    logStr=$logStr"tx_ok=$TX_OK;tx_fail=$TX_FAIL;tx_retry=$TX_RETRY;rx_ok=$RX_OK;rx_fcs=$RX_FCS;"
    logStr=$logStr"cck_false=$CCK_ERR;cck_crc=$CCK_CRC;ofdm_false=$OFDM_ERR;ofdm_crc=$OFDM_CRC;"
    log -t $LOGCATTAG $logStr
    TXOPSCALE=$(($ChanIdle/10))
}

# Log the maximum and minimum values regarding signal quality
function log_maxmin_signals
{
    if [[ ! "$PREVIOUS_CHANNEL" ]] ; then
        PREVIOUS_CHANNEL=$CHANNEL
    elif [[ $PREVIOUS_CHANNEL != $CHANNEL ]] ; then
        PREVIOUS_CHANNEL=$CHANNEL
        MAX_RSSI=''
        MIN_RSSI=''
        MAX_NOISE=''
        MIN_NOISE=''
    fi

    if [[ ! "$PREVIOUS_INTERFACE" ]] ; then
        PREVIOUS_INTERFACE=$WLAN_INTERFACE
    elif [[ $PREVIOUS_INTERFACE != $WLAN_INTERFACE ]] ; then
        PREVIOUS_INTERFACE=$WLAN_INTERFACE
        MAX_RSSI=''
        MIN_RSSI=''
        MAX_NOISE=''
        MIN_NOISE=''
    fi

    if [[ ! "$MAX_RSSI" && ! "$MIN_RSSI" && ! "$maxRssi" -eq 0 ]] ; then
        MAX_RSSI=$maxRssi
        MIN_RSSI=$maxRssi
    fi

    if [[ ! "$MAX_NOISE" && ! "$MIN_NOISE" && ! "$maxNoise" -eq 0 ]] ; then
        MAX_NOISE=$maxNoise
        MIN_NOISE=$maxNoise
    fi


    if [[ ! $maxRssi -eq 0 ]] ; then
        if [ $maxRssi -gt $MAX_RSSI ] ; then
            MAX_RSSI=$maxRssi
        fi

        if [ $maxRssi -lt $MIN_RSSI ] ; then
            MIN_RSSI=$maxRssi
        fi
    fi

    if [[ ! $maxNoise -eq 0 ]] ; then
        if [ $maxNoise -gt $MAX_NOISE ] ; then
            MAX_NOISE=$maxNoise
        fi

        if [ $maxNoise -lt $MIN_NOISE ] ; then
            MIN_NOISE=$maxNoise
        fi
    fi


    logStr="max_rssi=$MAX_RSSI;min_rssi=$MIN_RSSI;max_noise=$MAX_NOISE;min_noise=$MIN_NOISE;"
    logStr=$logStr"noise histogram=${NOISE_FLOOR[@]}"
    log -t $LOGCATTAG $logStr
}

function clear_stale_stats
{
    BEACONRSSI=""
    NOISE=""
    RSSI=""
}

function log_mcs_per
{
    IFS=$'\n'
    TOTAL=10
    logStr=""
    # collect PER per MCS
    MCS_STATS=($($IWPRIV $WLAN_INTERFACE driver "GET_MCS_INFO"))

    for line in ${MCS_STATS[@]}; do
        if [[ $line == *"*" ]]; then
            string_trimmed_star=${line%%\**}
            STAR_NUM=$((${#line}-${#string_trimmed_star}))
            PERCENT=$((100*$STAR_NUM/$TOTAL))
            string_trimmed_star=`echo "$string_trimmed_star" | xargs`
            if [[ $line == *"PER"* ]]; then
                PER=${string_trimmed_star: -4:3}
                PER=${PER%%\]}
                RATE=${string_trimmed_star%%\ \[*}
                logStr=$logStr"TXRATE=$RATE; PER=$PER; PERCNT=$PERCENT%;"
            else
                logStr=$logStr"RXRATE=$string_trimmed_star; PERCNT=$PERCENT%;"
            fi
        fi
    done
    unset IFS
    log -t $LOGCATTAG $logStr
}

function log_kernel_stat
{
    logStr="tx_packets=$TXPACKETS;tx_bytes=$TXBYTES;tx_errors=$TXERRORS;tx_dropped=$TXDROPPED;"
    logStr=$logStr"rx_packets=$RXPACKETS;rx_bytes=$RXBYTES;rx_errors=$RXERRORS;rx_dropped=$RXDROPPED;"
    logStr=$logStr$arp_flag
    log -t $LOGCATTAG $logStr
}

function run ()
{
    set_wlan_interface
    RSSI_THRESHOLDS=`getprop persist.wifi.rssi.thresholds`

    if [[ "$RSSI_THRESHOLDS" == "" ]] ; then
        RSSI_THRESHOLDS=$DEFAULT_RSSI_THD
    fi

    typeset IFS=","
    i=0
    for thd in $RSSI_THRESHOLDS; do
        RSSITHD[i++]=$thd
    done
    unset IFS

    if [[ -n $WLAN_INTERFACE_UP ]]; then
        if [[ $WLANINTF = "Down" ]]; then
            WLANINTF="Up"
            chip_nss=`$IWPRIV $WLAN_INTERFACE driver "get_cfg Nss"`
            CHIPNSS=${chip_nss#*:}
            $IWPRIV $WLAN_INTERFACE driver "set_fwlog 0 2 1" > /dev/null
            # enable PER per MCS
            $IWPRIV $WLAN_INTERFACE driver "GET_MCS_INFO START" > /dev/null
        fi
        iwpriv_show_channel
        iwpriv_stat_tokens
        ifconfig_kernel_stat
        iwpriv_traffic_noise_report
        get_max_signal_stats
        arp_check
        log_logcat

        if [[ $currentLoop -ge $LOOPSTILMETRICS ]] && [[ "$WLAN_INTERFACE" !=  *"p2p"* ]]; then
            iwpriv_conn_status
            log_connstatus_metrics

            if [[ $CONN_STATUS = "Connected" ]]; then
                log_wifi_metrics
            fi
            currentLoop=0
        else
            ((currentLoop++))
        fi

        clear_stale_stats
    else
        WLANINTF="Down"
    fi
}


# Run the collection repeatedly, pushing all output through to the metrics log.
while true ; do
    run
    sleep $DELAY
done

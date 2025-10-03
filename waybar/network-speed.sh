#!/bin/bash
interface=$(ip route | grep default | awk '{print $5}' | head -n1)
rx1=$(cat /sys/class/net/$interface/statistics/rx_bytes)
tx1=$(cat /sys/class/net/$interface/statistics/tx_bytes)
sleep 1
rx2=$(cat /sys/class/net/$interface/statistics/rx_bytes)
tx2=$(cat /sys/class/net/$interface/statistics/tx_bytes)
rx_rate=$(((rx2-rx1)/1024))
tx_rate=$(((tx2-tx1)/1024))
printf "↓%dKB/s ↑%dKB/s" $rx_rate $tx_rate
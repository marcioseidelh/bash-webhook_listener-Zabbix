#!/bin/bash
# Idea taken from orginal Author: Jaroslav Stepanek

TCPPORT="12345"
PIDFILE="/var/tmp/webhook-listener.pid"
LOCKFILE="/var/tmp/webhook-listener.lock"
LOGFILE="/var/tmp/webhook-listener.log"

LISTENER_COMMAND="nc -l ${TCPPORT}"
LISTENER_REGEX='^POST'

function log() {
    echo "$(date) $*" >> "${LOGFILE}"
}

function lock() {
    if [ "${LOCKFILE}" ]; then
        touch "${LOCKFILE}"
    fi
}

function unlock() {
    if [ "${LOCKFILE}" ]; then
        rm -f "${LOCKFILE}"
    fi
}

function executeCommands() {
    if [ "${LOCKFILE}" ] && [ -f "${LOCKFILE}" ]; then
        log "Locked, no execution allowed"
    else
        lock
        local line="$1"
        local alert_message="Webhook alert: $line"
        zabbix_sender -z ZABBIX_SERVER_IP -s "Webhook Listener" -k webhook.alert -o "$alert_message"
        log "Alert sent to Zabbix: $alert_message"
        unlock
    fi
}

function startListener() {
    trap onExit SIGHUP SIGINT SIGTERM

    eval "${LISTENER_COMMAND}" | while read -r line; do
        if [[ "$line" =~ ${LISTENER_REGEX} ]]; then
            executeCommands "$line"
        fi
    done
}

function listen() {
    local mPid=0

    trap onExit SIGHUP SIGINT SIGTERM

    while true; do
        startListener >/dev/null &
        mPid=$!
        wait "${mPid}"
        sleep 1
    done
}

function onExit() {
    local ncPid=$(pgrep -f "${LISTENER_COMMAND}")
    kill "${ncPid}" &>/dev/null
    exit 0
}

function start() {
    local mPid=0

    status &>/dev/null
    if [ $? -gt 1 ]; then
        echo "Process already running"
        exit 0
    fi

    unlock

    listen &>/dev/null &
    mPid=$!
    disown "${mPid}"
    echo "${mPid}" > "${PIDFILE}"
}

function stop() {
    local mPid=$(cat "${PIDFILE}")

    if [ "${mPid}" ]; then
        kill "${mPid}" && rm -f "${PIDFILE}"
    fi

    unlock
}

function status() {
    local mPid=$(cat "${PIDFILE}" 2>/dev/null)

    if [ "${mPid}" ]; then
        ps -p "${mPid}" &>/dev/null

        if [ $? -eq 0 ]; then
            echo "Process is running with PID ${mPid}"
            return 1
        else
            echo "Process is not running but the PID file still exists!"
            return 0
        fi
    else
        echo "Process is stopped"
        return 0
    fi
}

function main() {
    local arg="${1}"
    
    case "${arg}" in
        start)
            start
            exit 0
            ;;
        stop)
            stop
            exit 0
            ;;
        status)
            status
            exit 0
            ;;
        restart)
            stop
            sleep 1
            start
            exit 0
            ;;
        *)
            echo "Usage: $0 {start|stop|status|restart}"
            exit 0
            ;;
    esac
}

main "$@"
exit 0

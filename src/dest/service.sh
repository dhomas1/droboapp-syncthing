#!/usr/bin/env sh
#
# SyncThing service - Optimized for Drobo 5N2

# import DroboApps framework functions
. /etc/service.subr

framework_version="2.1"
name="syncthing"
version="2.0.8"
description="Syncthing"
depends=""
webui=":8384/"

prog_dir="$(dirname "$(realpath "${0}")")"
data_dir="${prog_dir}/var"
daemon="${prog_dir}/app/syncthing"
tmp_dir="/tmp/DroboApps/${name}"
pidfile="${tmp_dir}/pid.txt"
logfile="${tmp_dir}/log.txt"
statusfile="${tmp_dir}/status.txt"
errorfile="${tmp_dir}/error.txt"

# backwards compatibility
if [ -z "${FRAMEWORK_VERSION:-}" ]; then
  framework_version="2.0"
  . "${prog_dir}/libexec/service.subr"
fi

# Performance optimization function
_optimize_system() {
  # Increase inotify watch limit for Syncthing
  sysctl -w fs.inotify.max_user_watches=204800 2>/dev/null || true
  
  # Optimize for low-memory systems
  echo 1 > /proc/sys/vm/swappiness 2>/dev/null || true
  
  # Set I/O scheduler to deadline for better responsiveness on spinning disks
  echo deadline > /sys/block/sda/queue/scheduler 2>/dev/null || true
  
  # Reduce dirty page cache to free memory faster
  echo 5 > /proc/sys/vm/dirty_background_ratio 2>/dev/null || true
  echo 10 > /proc/sys/vm/dirty_ratio 2>/dev/null || true
  
  echo "System optimizations applied" >> "${logfile}"
}

start() {
  export HOME="${data_dir}"
  export STNODEFAULTFOLDER='true'
  
  # Performance optimizations for ARM/low-memory systems
  export GOMAXPROCS=1                    # Single CPU core usage
  export GOGC=20                         # More aggressive GC
  export GOMEMLIMIT=100MiB              # Memory limit
  export GODEBUG=madvdontneed=1         # Better memory release
  
  # Apply system optimizations
  _optimize_system

  # Create tmpfs for temporary files if possible
  if [ ! -d "/tmp/syncthing-tmp" ]; then
    mkdir -p "/tmp/syncthing-tmp"
    # Try to mount as tmpfs (will fail silently if not possible)
    mount -t tmpfs -o size=16M,mode=0755 tmpfs "/tmp/syncthing-tmp" 2>/dev/null || true
  fi
  export TMPDIR="/tmp/syncthing-tmp"

  # Set process limits
  ulimit -v 131072  # 128MB virtual memory limit
  ulimit -n 1024    # File descriptor limit
  
  # Start with lower priority to prevent CPU hogging
  start-stop-daemon -S -m -b -x "${daemon}" -p "${pidfile}" -N 5 -- \
    serve \
    --gui-address="0.0.0.0:8384" \
    --home="${data_dir}" \
    --logfile="${logfile}" \
    --log-max-old-files=2 \
    --log-max-size=1048576 \
    --no-browser \
    --no-restart \
    --verbose=false

  rm -f "${errorfile}"
  echo "Syncthing is configured with performance optimizations." >"${statusfile}"
}

stop() {
  # Clean up tmpfs
  umount "/tmp/syncthing-tmp" 2>/dev/null || true
  rm -rf "/tmp/syncthing-tmp"
}

# Memory monitoring function
check_memory() {
  if [ -f "${pidfile}" ]; then
    local PID=$(cat "${pidfile}")
    if [ -n "$PID" ]; then
      local MEM_KB=$(ps -o pid,vsz | grep "^[[:space:]]*${PID}" | awk '{print $2}')
      if [ -n "$MEM_KB" ] && [ "$MEM_KB" -gt 204800 ]; then  # 200MB limit
        echo "$(date): Memory limit exceeded (${MEM_KB}KB), restarting..." >> "${logfile}"
        stop
        sleep 5
        start
      fi
    fi
  fi
}

# Override the main function to add memory checking
case "${1:-}" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart)
    stop
    start
    ;;
  status)
    status
    ;;
  check-memory)
    check_memory
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|check-memory}"
    exit 1
    ;;
esac

# boilerplate
if [ ! -d "${tmp_dir}" ]; then mkdir -p "${tmp_dir}"; fi
exec 3>&1 4>&2 1>> "${logfile}" 2>&1
STDOUT=">&3"
STDERR=">&4"
echo "$(date +"%Y-%m-%d %H-%M-%S"):" "${0}" "${@}"
set -o errexit  # exit on uncaught error code
set -o nounset  # exit on unset variable
set -o pipefail # propagate last error code on pipe
set -o xtrace   # enable script tracing

main "${@}"

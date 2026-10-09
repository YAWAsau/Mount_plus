#!/system/bin/sh
MODDIR=${0%/*}
# Independent boot-stage recovery. This runs once, not on a periodic timer.
sh "$MODDIR/service.sh" --boot-reconcile

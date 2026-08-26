#!/system/bin/sh
MODDIR=${0%/*}
CONTROL="$MODDIR/control.sh"

_info=$(sh "$CONTROL" primary_action_info 2>/dev/null)
_irc=$?
if [ "$_irc" -eq 10 ] || [ -z "$_info" ]; then
  echo '未設定可切換項目'
  exit 0
fi
if [ "$_irc" -ne 0 ]; then
  echo "讀取切換設定失敗（rc=$_irc）"
  exit "$_irc"
fi

_g=$(printf '%s\n' "$_info" | cut -d'|' -f1)
_cur=$(printf '%s\n' "$_info" | cut -d'|' -f3)
_next=$(printf '%s\n' "$_info" | cut -d'|' -f4)
_next_name=$(printf '%s\n' "$_info" | cut -d'|' -f5-)

printf '目前模式：%s\n' "$_cur"
printf '切換中：%s → %s\n' "$_cur" "$_next_name"
sh "$CONTROL" profile "$_g" "$_next" >/dev/null 2>&1
_rc=$?
if [ "$_rc" -eq 0 ]; then
  printf '切換成功：%s\n' "$_next_name"
else
  printf '切換失敗：%s → %s（rc=%s）\n' "$_cur" "$_next_name" "$_rc"
fi
exit "$_rc"

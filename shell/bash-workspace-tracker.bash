if [ -r "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi

__wezterm_workspace_base64() {
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    printf '%s' "$1" | base64 -w 0
  else
    printf '%s' "$1" | base64 | tr -d '\n'
  fi
}

__wezterm_workspace_set_user_var() {
  printf '\033]1337;SetUserVar=%s=%s\007' "$1" "$(__wezterm_workspace_base64 "$2")"
}

__wezterm_workspace_record_cwd() {
  __wezterm_workspace_set_user_var WEZTERM_WORKSPACE_CWD "$PWD"
}

__wezterm_workspace_record_command() {
  if [ "$__wezterm_workspace_in_prompt" = "1" ]; then
    return
  fi

  local command="$BASH_COMMAND"

  case "$command" in
    __wezterm_workspace_*|PROMPT_COMMAND=*|__wezterm_workspace_in_prompt=*|trap\ *|printf\ *|base64\ *|grep\ *|tr\ *) return ;;
  esac

  if [ -n "$command" ] && [ "$command" != "$__wezterm_workspace_last_command" ]; then
    __wezterm_workspace_last_command="$command"
    __wezterm_workspace_set_user_var WEZTERM_WORKSPACE_LAST_COMMAND "$command"
  fi
}

__wezterm_workspace_existing_prompt_command="$PROMPT_COMMAND"

if [ -n "$__wezterm_workspace_existing_prompt_command" ]; then
  PROMPT_COMMAND="__wezterm_workspace_record_cwd; __wezterm_workspace_in_prompt=1; $__wezterm_workspace_existing_prompt_command; __wezterm_workspace_in_prompt=0"
else
  PROMPT_COMMAND="__wezterm_workspace_record_cwd"
fi

trap '__wezterm_workspace_record_command' DEBUG
__wezterm_workspace_record_cwd

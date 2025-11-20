#! @shell@
set -e
set -o pipefail

if [[ $(id -u) -eq 0 ]]; then
  # On macOS, `sudo(8)` preserves `$HOME` by default, which causes Nix
  # to output warnings.
  HOME=~root
fi

export PATH=@path@
export NIX_PATH=${NIX_PATH:-@nixPath@}

# Use the daemon even as `root` so that resource limits, TLS and proxy
# configuration, etc. work as expected.
export NIX_REMOTE=${NIX_REMOTE:-daemon}

showSyntax() {
  echo "darwin-rebuild [--help] {edit | switch | activate | build | check | changelog}" >&2
  echo "               [--list-generations] [{--profile-name | -p} name] [--rollback]" >&2
  echo "               [{--switch-generation | -G} generation] [--verbose...] [-v...]" >&2
  echo "               [-Q] [{--max-jobs | -j} number] [--cores number] [--dry-run]" >&2
  echo "               [--keep-going | -k] [--keep-failed | -K] [--fallback] [--show-trace]" >&2
  echo "               [--print-build-logs | -L] [--impure] [-I path]" >&2
  echo "               [--option name value] [--arg name value] [--argstr name value]" >&2
  echo "               [--no-flake | [--flake flake]" >&2
  echo "                             [--commit-lock-file] [--recreate-lock-file]" >&2
  echo "                             [--no-update-lock-file] [--no-write-lock-file]" >&2
  echo "                             [--override-input input flake] [--update-input input]" >&2
  echo "                             [--no-registries] [--offline] [--refresh]]" >&2
  echo "               [--substituters substituters-list]" >&2
  echo "               [--use-substitutes|--substitute-on-destination|-s]" >&2
  echo "               [--build-host host] [--target-host host]" >&2
  echo "               [--sudo|--use-remote-sudo] [--no-ssh-tty]" >&2
  exit 1
}

# Parse the command line.
origArgs=("$@")
extraMetadataFlags=()
extraBuildFlags=()
extraFlakeBuildFlags=()
extraLockFlags=()
extraProfileFlags=()
copyFlags=()
buildHost=
targetHost=
useSudo=
noSSHTTY=
verboseScript=
activationEnv=()

log() {
  echo "$@" >&2
}

logVerbose() {
  if [[ -n $verboseScript ]]; then
    echo "$@" >&2
  fi
}

runCmd() {
  logVerbose "$" "$@"
  "$@"
}

buildHostCmd() {
  if [ -z "$buildHost" ]; then
    runCmd "$@"
  else
    runCmd ssh $SSHOPTS "$buildHost" "$@"
  fi
}

targetHostCmd() {
  local c=()
  if [[ "${withSudo:-x}" = 1 ]]; then
    c=("sudo")
  fi

  if [ -z "$targetHost" ]; then
    runCmd "${c[@]}" "$@"
  else
    runCmd ssh $SSHOPTS "$targetHost" "${c[@]}" "$@"
  fi
}

targetHostSudoCmd() {
  local t=
  local sshWithTTY="$SSHOPTS"

  if [[ ! "${noSSHTTY:-x}" = 1 ]]; then
    if [[ -n "$targetHost" ]]; then
      t="-tt"
      sshWithTTY="$SSHOPTS $t -o ControlMaster=no -o ControlPersist=no -S none"
    else
      t="-t"
      sshWithTTY="$SSHOPTS $t"
    fi
  fi

  if [[ -n "$useSudo" ]]; then
    withSudo=1 SSHOPTS="$sshWithTTY" targetHostCmd "$@"
  else
    SSHOPTS="$sshWithTTY" targetHostCmd "$@"
  fi
}

copyToTarget() {
  if [ "$targetHost" = "$buildHost" ]; then
    return
  fi

  if [ -z "$targetHost" ] && [ -z "$buildHost" ]; then
    return
  fi

  if [ -z "$targetHost" ]; then
    logVerbose "Running nix-copy-closure with these NIX_SSHOPTS: $SSHOPTS"
    NIX_SSHOPTS=$SSHOPTS runCmd nix-copy-closure "${copyFlags[@]}" --from "$buildHost" "$1"
  elif [ -z "$buildHost" ]; then
    logVerbose "Running nix-copy-closure with these NIX_SSHOPTS: $SSHOPTS"
    NIX_SSHOPTS=$SSHOPTS runCmd nix-copy-closure "${copyFlags[@]}" --to "$targetHost" "$1"
  else
    buildHostCmd nix-copy-closure "${copyFlags[@]}" --to "$targetHost" "$1"
  fi
}

nixLegacyBuild() {
  if [ -z "$buildHost" ]; then
    runCmd nix-build "$@"
  else
    local instArgs=()
    local buildArgs=()
    local drv=
    while [ "$#" -gt 0 ]; do
      local i=$1; shift 1
      case $i in
        -o)
          local out=$1; shift 1
          buildArgs+=("--add-root" "$out" "--indirect")
          ;;
        -A)
          local j=$1; shift 1
          instArgs+=("$i" "$j")
          ;;
        -I)
          shift 1
          ;;
        --no-out-link)
          ;;
        --arg|--argstr)
          shift 2
          ;;
        --substituters)
          shift 1
          ;;
        "<"*)
          instArgs+=("$i")
          ;;
        *)
          buildArgs+=("$i")
          ;;
      esac
    done

    drv="$(runCmd nix-instantiate "${instArgs[@]}" "${extraBuildFlags[@]}")"
    if [ -a "$drv" ]; then
      logVerbose "Running nix-copy-closure with these NIX_SSHOPTS: $SSHOPTS"
      NIX_SSHOPTS=$SSHOPTS runCmd nix-copy-closure "${copyFlags[@]}" --to "$buildHost" "$drv"
      buildHostCmd nix-store -r "$drv" "${buildArgs[@]}"
    else
      log "nix-instantiate failed"
      exit 1
    fi
  fi
}

nixFlakeBuild() {
  if [ -z "$buildHost" ]; then
    runCmd nix "${flakeFlags[@]}" build "${extraFlakeBuildFlags[@]}" "$@"
    readlink -f ./result
  else
    local attr=$1
    shift 1
    local evalArgs=()
    local buildArgs=()
    local drv=

    while [ "$#" -gt 0 ]; do
      local i=$1; shift 1
      case $i in
        --recreate-lock-file|--no-update-lock-file|--no-write-lock-file|--no-registries|--commit-lock-file)
          evalArgs+=("$i")
          ;;
        --update-input)
          local j=$1; shift 1
          evalArgs+=("$i" "$j")
          ;;
        --override-input)
          local j=$1; shift 1
          local k=$1; shift 1
          evalArgs+=("$i" "$j" "$k")
          ;;
        --impure)
          ;;
        *)
          buildArgs+=("$i")
          ;;
      esac
    done

    local evalExtraFlags=()
    for flag in "${extraBuildFlags[@]}"; do
      case "$flag" in
        --no-link)
          continue
          ;;
        *)
          evalExtraFlags+=("$flag")
          ;;
      esac
    done

    drv="$(runCmd nix "${flakeFlags[@]}" eval --raw "${attr}.drvPath" "${evalArgs[@]}" "${evalExtraFlags[@]}")"
    if [ -a "$drv" ]; then
      logVerbose "Running nix with these NIX_SSHOPTS: $SSHOPTS"
      NIX_SSHOPTS=$SSHOPTS runCmd nix "${flakeFlags[@]}" copy "${copyFlags[@]}" --derivation --to "ssh://$buildHost" "$drv"
      buildHostCmd nix-store -r "$drv" "${buildArgs[@]}"
    else
      log "nix eval failed"
      exit 1
    fi
  fi
}
profile=@profile@
action=
flake=
noFlake=

while [ $# -gt 0 ]; do
  i=$1; shift 1
  case $i in
    --help)
      showSyntax
      ;;
    edit|switch|activate|build|check|changelog)
      action=$i
      ;;
    --show-trace|--keep-going|--keep-failed|--verbose|-v|-vv|-vvv|-vvvv|-vvvvv|--fallback|--offline)
      extraMetadataFlags+=("$i")
      extraBuildFlags+=("$i")
      if [[ "$i" == --verbose || "$i" == -v* ]]; then
        verboseScript=1
      fi
      ;;
    --no-build-hook|--dry-run|-k|-K|-Q)
      extraBuildFlags+=("$i")
      ;;
    -j[0-9]*)
      extraBuildFlags+=("$i")
      ;;
    --max-jobs|-j|--cores|-I)
      if [ $# -lt 1 ]; then
        echo "$0: '$i' requires an argument"
        exit 1
      fi
      j=$1; shift 1
      extraBuildFlags+=("$i" "$j")
      ;;
    --arg|--argstr|--option)
      if [ $# -lt 2 ]; then
        echo "$0: '$i' requires two arguments"
        exit 1
      fi
      j=$1
      k=$2
      shift 2
      extraMetadataFlags+=("$i" "$j" "$k")
      extraBuildFlags+=("$i" "$j" "$k")
      ;;
    --flake)
      flake=$1
      shift 1
      ;;
    --no-flake)
      noFlake=1
      ;;
    -L|-vL|--print-build-logs|--impure|--recreate-lock-file|--no-update-lock-file|--no-write-lock-file|--no-registries|--commit-lock-file|--refresh)
      extraLockFlags+=("$i")
      ;;
    --update-input)
      j="$1"; shift 1
      extraLockFlags+=("$i" "$j")
      ;;
    --override-input)
      j="$1"; shift 1
      k="$1"; shift 1
      extraLockFlags+=("$i" "$j" "$k")
      ;;
    --list-generations)
      action="list"
      extraProfileFlags=("$i")
      ;;
    --rollback)
      action="rollback"
      extraProfileFlags=("$i")
      ;;
    --switch-generation|-G)
      action="rollback"
      if [ $# -lt 1 ]; then
        echo "$0: '$i' requires an argument"
        exit 1
      fi
      j=$1; shift 1
      extraProfileFlags=("$i" "$j")
      ;;
    --profile-name|-p)
      if [ -z "$1" ]; then
        echo "$0: '$i' requires an argument"
        exit 1
      fi
      if [ "$1" != system ]; then
        profile="/nix/var/nix/profiles/system-profiles/$1"
        mkdir -p -m 0755 "$(dirname "$profile")"
      fi
      shift 1
      ;;
    --substituters)
      if [ -z "$1" ]; then
        echo "$0: '$i' requires an argument"
        exit 1
      fi
      j=$1; shift 1
      extraMetadataFlags+=("$i" "$j")
      extraBuildFlags+=("$i" "$j")
      ;;
    --use-substitutes|--substitute-on-destination|-s)
      copyFlags+=("-s")
      ;;
    --build-host)
      if [ -z "$1" ]; then
        echo "$0: '$i' requires an argument"
        exit 1
      fi
      buildHost="$1"
      shift 1
      ;;
    --target-host)
      if [ -z "$1" ]; then
        echo "$0: '$i' requires an argument"
        exit 1
      fi
      targetHost="$1"
      shift 1
      ;;
    --sudo|--use-remote-sudo)
      useSudo=1
      ;;
    --no-ssh-tty)
      noSSHTTY=1
      ;;
    *)
      echo "$0: unknown option '$i'"
      exit 1
      ;;
  esac
done

if [ -z "$action" ]; then showSyntax; fi

if [[ $action =~ ^switch|activate|rollback|check$ && -z "$targetHost" && $(id -u) -ne 0 ]]; then
  printf >&2 '%s: system activation must now be run as root\n' "$0"
  exit 1
fi

tmpDir=$(mktemp -d "${TMPDIR:-/tmp}/darwin-rebuild.XXXXXX")
if [[ ${#tmpDir} -ge 60 ]]; then
  rmdir "$tmpDir"
  tmpDir=$(TMPDIR=/tmp mktemp -d darwin-rebuild.XXXXXX)
fi

cleanup() {
  for ctrl in "$tmpDir"/ssh-*; do
    ssh -o ControlPath="$ctrl" -O exit dummyhost 2>/dev/null || true
  done
  rm -rf "$tmpDir"
}
trap cleanup EXIT

SSHOPTS=${NIX_SSHOPTS:-}
SSHOPTS="$SSHOPTS -o ControlMaster=auto -o ControlPath=$tmpDir/ssh-%n -o ControlPersist=60"

flakeFlags=(--extra-experimental-features 'nix-command flakes')

# Use /etc/nix-darwin/flake.nix if it exists. It can be a symlink to the
# actual flake.
if [[ -z $flake && -e /etc/nix-darwin/flake.nix && -z $noFlake ]]; then
  flake="$(dirname "$(readlink -f /etc/nix-darwin/flake.nix)")"
fi

# For convenience, use the hostname as the default configuration to
# build from the flake.
if [[ -n "$flake" ]]; then
    if [[ $flake =~ ^(.*)\#([^\#\"]*)$ ]]; then
       flake="${BASH_REMATCH[1]}"
       flakeAttr="${BASH_REMATCH[2]}"
    fi
    if [[ -z "$flakeAttr" ]]; then
      if [ -n "$targetHost" ]; then
        if ! flakeAttr=$(targetHostCmd scutil --get LocalHostName); then
          flakeAttr=$(targetHostCmd hostname || true)
        fi
      else
        flakeAttr=$(scutil --get LocalHostName)
      fi
      : "${flakeAttr:=default}"
    fi
    flakeAttr=darwinConfigurations.${flakeAttr}
fi

if [ "$action" != build ]; then
  if [ -n "$flake" ]; then
    extraFlakeBuildFlags+=("--no-link")
  else
    extraBuildFlags+=("--no-out-link")
  fi
fi

if [ "$action" = edit ]; then
  if [ -z "$flake" ]; then
    darwinConfig=$(nix-instantiate "${extraBuildFlags[@]}" --find-file darwin-config)
    exec "${EDITOR:-vi}" "$darwinConfig"
  else
    exec nix "${flakeFlags[@]}" edit "${extraLockFlags[@]}" -- "$flake#$flakeAttr"
  fi
fi

if [ "$action" = switch ] || [ "$action" = build ] || [ "$action" = check ] || [ "$action" = changelog ]; then
  echo "building the system configuration..." >&2
  if [ -z "$flake" ]; then
    systemConfig="$(nixLegacyBuild '<darwin>' "${extraBuildFlags[@]}" -A system)"
  else
    if [ -n "$buildHost" ]; then
      systemConfig="$(nixFlakeBuild "$flake#$flakeAttr.system" "${extraBuildFlags[@]}" "${extraLockFlags[@]}")"
    else
      systemConfig=$(
        nix "${flakeFlags[@]}" build --json \
          "${extraFlakeBuildFlags[@]}" "${extraBuildFlags[@]}" "${extraLockFlags[@]}" \
          -- "$flake#$flakeAttr.system" \
          | jq -r '.[0].outputs.out'
      )
    fi
  fi
  copyToTarget "$systemConfig"
fi

if [ "$action" = list ]; then
  targetHostCmd nix-env -p "$profile" "${extraProfileFlags[@]}"
fi

if [ "$action" = rollback ]; then
  targetHostSudoCmd nix-env -p "$profile" "${extraProfileFlags[@]}"
  if [ -n "$targetHost" ]; then
    systemConfig="$(
      targetHostSudoCmd cat "$profile/systemConfig" | tr -d '\r'
    )"
  else
    systemConfig="$(cat "$profile/systemConfig")"
  fi
fi

if [ "$action" = activate ]; then
  if [ -n "$targetHost" ]; then
    systemConfig="$(
      targetHostSudoCmd cat "$profile/systemConfig" | tr -d '\r'
    )"
  else
    systemConfig=$(readlink -f "${0%*/sw/bin/darwin-rebuild}")
  fi
fi

if [ -z "$systemConfig" ]; then exit 0; fi

# TODO: Remove this backwards‐compatibility hack in 25.11.

if
  [[ -x $systemConfig/activate-user ]] \
  && ! grep -q '^# nix-darwin: deprecated$' "$systemConfig/activate-user"
then
  hasActivateUser=1
else
  hasActivateUser=
fi

runActivateUser() {
  local userCmd=("$systemConfig/activate-user")
  if [ ${#activationEnv[@]} -gt 0 ]; then
    userCmd=("${activationEnv[@]}" "$systemConfig/activate-user")
  fi

  if [ -z "$targetHost" ]; then
    if [[ -n $SUDO_USER ]]; then
      sudo --user="$SUDO_USER" --set-home -- "${userCmd[@]}"
    else
      printf >&2 \
        '%s: $SUDO_USER not set, can’t run legacy `activate-user` script\n' \
        "$0"
      exit 1
    fi
  else
    local userCmdStr
    printf -v userCmdStr '%q ' "${userCmd[@]}"
    userCmdStr=${userCmdStr% }
    targetHostCmd sh -c '
      if [ "$(id -u)" -ne 0 ]; then
        '"$userCmdStr"'
      else
        printf >&2 "%s: $SUDO_USER not set, can’t run legacy `activate-user` script\n" '"$(printf '%q' "$0")"'
        exit 1
      fi
    '
  fi
}

if [ "$action" = switch ]; then
  targetHostSudoCmd nix-env -p "$profile" --set "$systemConfig"
fi

if [ "$action" = switch ] || [ "$action" = activate ] || [ "$action" = rollback ]; then
  if [[ -n $hasActivateUser ]]; then
    runActivateUser
  fi
  activateCmd=("$systemConfig/activate")
  if [ ${#activationEnv[@]} -gt 0 ]; then
    activateCmd=("${activationEnv[@]}" "$systemConfig/activate")
  fi
  if [ -n "$targetHost" ]; then
    targetHostSudoCmd "${activateCmd[@]}"
  else
    "${activateCmd[@]}"
  fi
fi

if [ "$action" = changelog ]; then
  if [ -n "$targetHost" ]; then
    targetHostCmd cat "$systemConfig/darwin-changes" | ${PAGER:-less}
  else
    ${PAGER:-less} -- "$systemConfig/darwin-changes"
  fi
fi

if [ "$action" = check ]; then
  checkActivation=1
  export checkActivation
  activationEnv=(env checkActivation="$checkActivation")
  if [[ -n $hasActivateUser ]]; then
    runActivateUser
  else
    activateCmd=("$systemConfig/activate")
    activateCmd=("${activationEnv[@]}" "$systemConfig/activate")
    if [ -n "$targetHost" ]; then
      targetHostSudoCmd "${activateCmd[@]}"
    else
      "${activateCmd[@]}"
    fi
  fi
  activationEnv=()
fi

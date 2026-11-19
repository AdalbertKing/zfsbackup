#!/bin/bash
# install.sh -- first install of zfsbackup on a Proxmox / Debian host, in one command.
#
# Fetch it alone and run it as root:
#
#   wget -O install.sh https://raw.githubusercontent.com/AdalbertKing/zfsbackup/main/install.sh
#   bash install.sh --check      # nothing is changed: dependencies and what is still missing
#   bash install.sh              # the install itself
#
# What it does, in this order (the same steps as docs/pl/ESENCJA.md "Pierwsze uruchomienie"):
#   1. git: installed with apt-get when missing (--check refuses instead: it changes nothing).
#   2. The package directory (default /root/scripts/zfs-snapshot-all):
#      - missing             -> git clone of the release repository;
#      - a git clone already -> left as it is (updates come from update-control.sh, hourly);
#      - old scripts, no .git -> refused, unless --move-old: the root crontab is saved to
#        $HOME/crontab.bak-<time> (/root for root), the directory is moved to <dir>.old-<time>
#        and every root crontab line that names <dir> -- "<dir>/x" or "cd <dir> && ./x", also
#        commented out -- is pointed at <dir>.old-<time>. Those jobs keep running the old
#        scripts and do not start the new package's scripts of the same name (snapsend.sh)
#        with their old arguments. A job that reaches <dir> another way (a variable, a
#        symlink, another user's crontab) is not seen: check those yourself.
#        Fail closed: a crontab that cannot be read (anything but "no crontab for root") stops
#        before the move; a failed install or read-back of the new crontab puts the crontab
#        and the directory back and stops before the clone.
#   3. deploy.sh --backup-user=zfsbackup, plus every option this script does not know
#      (--allow-quiesce, --grant-datasets=..., --test-mail, ...). --no-account: deploy.sh
#      without --backup-user.
#   4. Prints what is left to the admin: the first relation (zfs-backup gui, F3, Ins) and the
#      root crontab lines outside the package that mention zfs, snapsend, snapget, syncoid or
#      zrep -- old backup jobs to be
#      switched off once the relation runs. It never edits those itself.
#
# Exit status: 0 done; 1 refused or failed (the message says which step); with --check,
# deploy.sh --check-only's own status.
set -u

URL="https://github.com/AdalbertKing/zfsbackup.git"
DIR="/root/scripts/zfs-snapshot-all"
CHECK=0
MOVE_OLD=0
ACCOUNT="zfsbackup"
DEPLOY_ARGS=()

usage() {
    cat <<'EOF'
usage: install.sh [--check] [--move-old] [--no-account] [--dir=DIR] [--url=URL] [deploy.sh options...]

  --check        change nothing: clone into a temporary directory and run deploy.sh --check-only
  --move-old     DIR holds old scripts without .git: move it aside and repoint the root crontab
  --no-account   run deploy.sh without --backup-user=zfsbackup (the jobs then run as root)
  --dir=DIR      package directory (default /root/scripts/zfs-snapshot-all)
  --url=URL      repository to clone (default https://github.com/AdalbertKing/zfsbackup.git)
  any other option is passed to deploy.sh, e.g. --allow-quiesce, --grant-datasets=hdd
EOF
}

for a in "$@"; do
    case "$a" in
        --check)       CHECK=1 ;;
        --move-old)    MOVE_OLD=1 ;;
        --no-account)  ACCOUNT="" ;;
        --dir=?*)      DIR="${a#--dir=}" ;;
        --url=?*)      URL="${a#--url=}" ;;
        -h|--help)     usage; exit 0 ;;
        *)             DEPLOY_ARGS+=("$a") ;;
    esac
done
DIR="${DIR%/}"

say()  { printf 'install: %s\n' "$*"; }
die()  { printf 'install: ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (the package installs into /root, /etc and /usr/local/bin)"
case "$DIR" in /*) ;; *) die "--dir must be an absolute path: $DIR" ;; esac

# --- 1. git -------------------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    [ "$CHECK" = 1 ] && die "git is missing; --check changes nothing -- install it first: apt-get install -y git"
    say "git is missing: apt-get install -y git"
    apt-get install -y git || die "apt-get install git failed"
    command -v git >/dev/null 2>&1 || die "git is still missing after apt-get"
fi

# --- --check: a throw-away clone, nothing on the host changes ------------------------------------
if [ "$CHECK" = 1 ]; then
    tmp="$(mktemp -d)" || die "mktemp failed"
    trap 'rm -rf "$tmp"' EXIT
    say "check: git clone $URL (temporary, $tmp)"
    git clone -q "$URL" "$tmp/zfsbackup" || die "git clone $URL failed"
    say "check: version $(git -C "$tmp/zfsbackup" log -1 --format='%h %cd' --date=short)"
    if [ -d "$DIR/.git" ]; then
        say "check: $DIR is a git clone already -- install.sh would leave it and re-run deploy.sh"
    elif [ -e "$DIR" ]; then
        say "check: $DIR exists without .git -- install.sh refuses without --move-old"
    else
        say "check: $DIR does not exist -- install.sh would clone there"
    fi
    ( cd "$tmp/zfsbackup" && ./deploy.sh --check-only )
    exit $?
fi

# --- 2. the package directory --------------------------------------------------------------------
# repoint LINE FROM TO: every occurrence of the path FROM that ends there -- followed by "/", a
# blank, ; & | ' " ) or the end of the line -- becomes TO. "cd FROM && ./snapsend.sh" is caught
# as well as "FROM/snapsend.sh"; "FROM-other/x" and "FROM.old/x" are not.
repoint() {
    local rest="$1" from="$2" to="$3" out="" pre c
    while [[ $rest == *"$from"* ]]; do
        pre="${rest%%"$from"*}"
        rest="${rest#*"$from"}"
        c="${rest:0:1}"
        case "$c" in
            ''|/|' '|$'\t'|';'|'&'|'|'|"'"|'"'|')') out+="$pre$to" ;;
            *) out+="$pre$from" ;;
        esac
    done
    printf '%s\n' "$out$rest"
}

names_dir() { [ "$(repoint "$1" "$DIR" "$DIR.x")" != "$1" ]; }   # LINE names $DIR

# read_root_crontab FILE: root's crontab into FILE. rc 0 also for a root without a crontab (cron
# says "no crontab for root"; FILE is then empty). Any other failure (spool, permission, I/O)
# returns 1 with cron's message in CRONTAB_ERR -- never read as "no crontab" (#1313): the caller
# would otherwise move the directory, repoint nothing and clone new scripts under old paths.
CRONTAB_ERR=""
read_root_crontab() {
    local err rc
    err="$(crontab -u root -l 2>&1 >"$1")"; rc=$?
    [ "$rc" = 0 ] && return 0
    case "$err" in
        "no crontab for root"*) : > "$1"; return 0 ;;
    esac
    CRONTAB_ERR="${err:-crontab -l rc=$rc, no message}"
    return 1
}

crontab_lines_naming_dir() {   # rc 1 when root's crontab cannot be read
    local l f
    f="$(mktemp)" || return 1
    read_root_crontab "$f" || { rm -f "$f"; return 1; }
    while IFS= read -r l || [ -n "$l" ]; do
        if names_dir "$l"; then printf '%s\n' "$l"; fi
    done < "$f"
    rm -f "$f"
}

move_old() {
    local ts old bak new l n=0 had=1 cur
    ts="$(date +%Y%m%d-%H%M%S)"
    old="$DIR.old-$ts"
    bak="${HOME:-/root}/crontab.bak-$ts"
    [ -e "$old" ] && die "$old exists already"
    # 1. Read and save root's crontab BEFORE anything moves. Unreadable = stop, nothing changed.
    read_root_crontab "$bak" \
        || { rm -f "$bak"; die "cannot read root's crontab ($CRONTAB_ERR) -- nothing was moved; fix cron and re-run"; }
    [ -s "$bak" ] || had=0
    say "root crontab saved to $bak ($(wc -l < "$bak") lines)"
    new="$(mktemp)" || die "mktemp failed -- nothing was moved"
    while IFS= read -r l || [ -n "$l" ]; do
        if names_dir "$l"; then n=$((n+1)); fi
        repoint "$l" "$DIR" "$old"
    done < "$bak" > "$new"
    # 2. Move, then repoint. Any failure from here puts the directory and the crontab back and
    #    stops before the clone, so no new script ever lands under a path an old job still uses.
    mv -- "$DIR" "$old" || { rm -f "$new"; die "mv $DIR $old failed -- nothing was moved"; }
    say "old scripts moved: $DIR -> $old"
    if [ "$n" -gt 0 ]; then
        cur="$(mktemp)" || { rm -f "$new"; undo_move "$old" "$bak" "$had" "mktemp failed"; }
        if ! crontab -u root "$new"; then
            rm -f "$new" "$cur"; undo_move "$old" "$bak" "$had" "crontab could not be installed"
        fi
        if ! read_root_crontab "$cur" || ! cmp -s "$cur" "$new"; then
            rm -f "$new" "$cur"; undo_move "$old" "$bak" "$had" "crontab read back differs from what was written"
        fi
        rm -f "$cur"
        say "root crontab: $n line(s) now point at $old (read back)"
    fi
    rm -f "$new"
}

# undo_move OLD BAK HAD REASON: put root's crontab (BAK; none when HAD=0) and the directory back,
# then stop. Says exactly what it could not restore.
undo_move() {
    local old="$1" bak="$2" had="$3" why="$4" cr=unchanged dr=ok f
    f="$(mktemp)" || f=/dev/null
    if ! read_root_crontab "$f" || ! cmp -s "$f" "$bak"; then
        cr=ok
        if [ "$had" = 1 ]; then
            crontab -u root "$bak" 2>/dev/null || cr="FAILED -- restore it by hand: crontab $bak"
        else
            crontab -u root -r 2>/dev/null || cr="FAILED -- remove it by hand: crontab -r"
        fi
    fi
    [ "$f" = /dev/null ] || rm -f "$f"
    mv -- "$old" "$DIR" 2>/dev/null || dr="FAILED -- move it back by hand: mv $old $DIR"
    die "$why. Restored: crontab $cr, directory $dr. Nothing was cloned."
}

if [ -d "$DIR/.git" ]; then
    say "$DIR is a git clone already ($(git -C "$DIR" log -1 --format=%h 2>/dev/null)) -- not cloned again"
elif [ -e "$DIR" ]; then
    if [ "$MOVE_OLD" != 1 ]; then
        if ! lines="$(crontab_lines_naming_dir)"; then
            say "root crontab could not be read -- check it for jobs that use $DIR"
        elif [ -n "$lines" ]; then
            say "root crontab lines that use it:"
            printf '%s\n' "$lines" | sed 's/^/    /'
        fi
        die "$DIR exists without .git (old scripts?). Re-run with --move-old to move it aside and repoint the root crontab, or move it yourself."
    fi
    move_old
fi

if [ ! -e "$DIR" ]; then
    mkdir -p -- "$(dirname -- "$DIR")" || die "cannot create $(dirname -- "$DIR")"
    say "git clone $URL $DIR"
    git clone -q "$URL" "$DIR" || die "git clone $URL failed"
fi

# --- 3. deploy.sh --------------------------------------------------------------------------------
[ -x "$DIR/deploy.sh" ] || [ -f "$DIR/deploy.sh" ] || die "$DIR/deploy.sh not found -- is $URL the zfsbackup repository?"
set -- ${ACCOUNT:+"--backup-user=$ACCOUNT"} ${DEPLOY_ARGS[@]+"${DEPLOY_ARGS[@]}"}
say "deploy.sh $*"
( cd "$DIR" && bash ./deploy.sh "$@" ) || die "deploy.sh failed (rc=$?); its log says why"

# --- 4. what is left -----------------------------------------------------------------------------
say "done. Next:"
say "  1. the first relation: zfs-backup gui -> F3 Relations, Ins (the wizard shows the plan before Run)"
ct="$(mktemp)" || exit 0
if ! read_root_crontab "$ct"; then
    say "  2. root crontab could not be read ($CRONTAB_ERR) -- check it for old backup jobs yourself"
    rm -f "$ct"; exit 0
fi
others="$(grep -v '^[[:space:]]*#' "$ct" | grep -i 'zfs\|snapsend\|snapget\|syncoid\|zrep' | grep -vF -- "$DIR/")"
rm -f "$ct"
if [ -n "$others" ]; then
    say "  2. root crontab lines outside the package that mention zfs/snapsend/snapget/syncoid/zrep -- switch the old backup jobs off once the relation runs:"
    printf '%s\n' "$others" | sed 's/^/       /'
fi
exit 0

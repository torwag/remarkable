#!/bin/bash

# Author Kim Covil
#
# Inspired by stucule's maxio script from reddit
# https://www.reddit.com/r/RemarkableTablet/comments/7blo1k/suggestion_network_drive_in_myfiles/
#
# Uses hardlinks for unedited files
# Uses wget to download edited files
# Uses associative arrays for maps
# Uses awk for data extraction from metadata files

# Standard variables
BASE="/home/root/.local/share/remarkable"
SRCROOT="${BASE}/xochitl"
TGTROOT="${BASE}/file-tree"
URL="http://10.11.99.1/download"
# rclone support if available (http://rclone.org)
RCLONE="rclone" # change to the rclone binary (add the path if rclone is outside of $PATH)
RCLONE_CONFIG="/home/root/.rclone.conf" # change to the config file created by 'rclone config'
UPLOAD="cloud:reMarkable" # sync to a reMarkable folder on the remote rclone storage "cloud"

# Flags
VERBOSE=
QUIET=
DEBUG=
SYNC=
HELP=
WGET_FLAGS="-q"

[[ -s "${HOME}/.file-treerc" ]] && . "${HOME}/.file-treerc"

typeset -A PARENT
typeset -A NAME
typeset -A TYPE
typeset -A FULL
typeset -A EXT
typeset -A UUIDS
typeset -a FILES
typeset -a DIRS

while getopts "dvshq" OPT
do
    case "${OPT}" in
        v) VERBOSE=1; QUIET=; WGET_FLAGS=;;
        q) QUIET=1;;
        d) DEBUG=1;;
        s) SYNC=1;;
        h) HELP=1;;
        \?) echo "Invalid option: -${OPTARG}" >&2; HELP=1;;
    esac
done

shift $((OPTIND-1))

if [[ -n "${HELP}" ]]
then
    cat <<EOHELP
Usage: $0 [-vqdsh]
    -v    verbose
    -q    quiet
    -d    debug
    -s    sync
    -h    this help
EOHELP
    exit
fi

if [[ -n "${DEBUG}" ]]
then
    set -o xtrace
fi

[[ -z "${QUIET}" ]] && echo "Building metadata maps..."
for D in "${SRCROOT}/"*.metadata
do
    UUID="$(basename "${D}" ".metadata")"
    PARENT["${UUID}"]="$(awk -F\" '$2=="parent"{print $4}' "${D}")"
    NAME["${UUID}"]="$(awk -F\" '$2=="visibleName"{print $4}' "${D}")"
    TYPE["${UUID}"]="$(awk -F\" '$2=="type"{print $4}' "${D}")"
    if [[ "${TYPE["${UUID}"]}" == "DocumentType" ]]
    then
        FILES+=( "${UUID}" )
        EXT["${UUID}"]="$(awk -F\" '$2=="fileType"{print $4}' "${D%.metadata}.content")"
        if [[ -z "${EXT["${UUID}"]}" && -s "${D%.metadata}.lines" ]]
        then
            EXT["${UUID}"]="pdf"
        fi
    elif [[ "${TYPE["${UUID}"]}" == "CollectionType" ]]
    then
        DIRS+=( "${UUID}" )
    else
        echo "WARN: UUID ${UUID} has an unknown type ${TYPE["${UUID}"]}" >&2
    fi
done

[[ -z "${QUIET}" ]] && echo "Updating ${TGTROOT}/ ..."
for F in "${FILES[@]}"
do
    FULL["${F}"]="${NAME[${F}]}"
    P="${PARENT["${F}"]}"
    while [[ "${P}" != "" ]]
    do
        if [[ -n "${FULL["${P}"]}" ]]
        then
            FULL["${F}"]="${FULL[${P}]}/${FULL["$F"]}"
            break
        else
            FULL["${F}"]="${NAME[${P}]}/${FULL["$F"]}"
        fi
        P="${PARENT["${P}"]}"
    done
    if [[ -n "${PARENT["${F}"]}" && -z "${FULL["${PARENT["${F}"]}"]}" ]]
    then
        FULL["${PARENT["${F}"]}"]="$(dirname "${FULL["${F}"]}")"
    fi

    TARGET="${FULL["${F}"]}.${EXT["${F}"]}"
    [[ -n "${VERBOSE}" ]] && echo "UUID ${F} -> ${TARGET}"
    UUIDS["${TARGET}"]="${F}"
    [[ -n "${P}" ]] && UUIDS["${FULL["${P}"]}"]="${P}"

    mkdir -p "${TGTROOT}/$(dirname "${TARGET}")"
    if [[ ! -s "${SRCROOT}/${F}.lines" && -s "${SRCROOT}/${F}.${EXT["${F}"]}" ]]
    then
        if [[ ! "${SRCROOT}/${F}.${EXT["${F}"]}" -ef "${TGTROOT}/${TARGET}" ]]
        then
            [[ -z "${QUIET}" ]] && echo "Linking ${SRCROOT}/${F}.${EXT["${F}"]} to ${TGTROOT}/${TARGET}"
            ln -f "${SRCROOT}/${F}.${EXT["${F}"]}" "${TGTROOT}/${TARGET}"
        else
            [[ -n "${VERBOSE}" ]] && echo "Link ${TGTROOT}/${TARGET}"
        fi
    elif [[ "${SRCROOT}/${F}.metadata" -nt "${TGTROOT}/${TARGET}" ]]
    then
        [[ -z "${QUIET}" ]] && echo "Downloading ${TGTROOT}/${TARGET} from ${URL}/${F}/${EXT["${F}"]}"
        rm -f "${TGTROOT}/${TARGET}"
        touch -r "${SRCROOT}/${F}.metadata" "${TGTROOT}/${TARGET}"
        wget ${WGET_FLAGS} -O "${TGTROOT}/${TARGET}" "${URL}/${F}/${EXT["${F}"]}"
    else
        [[ -n "${VERBOSE}" ]] && echo "Clone ${TGTROOT}/${TARGET}"
    fi
done

find "${TGTROOT}" -type f | while read F
do
    F="${F#${TGTROOT}/}"
    if [[ -z "${UUIDS["${F}"]}" ]]
    then
        [[ -z "${QUIET}" ]] && echo "Deleting ${F} as looks to have been removed."
        rm "${TGTROOT}/${F}"
    fi
done

if [[ -n "${SYNC}" ]]
then
    if [[ -n "${RCLONE}" && -x "${RCLONE}" && -n "${UPLOAD}" ]]
    then
        [[ -z "${QUIET}" ]] && echo "Syncing ${TGTROOT}/ to ${UPLOAD}/ ..."
        "${RCLONE}" sync ${VERBOSE:+--verbose} --config ${RCLONE_CONFIG} --delete-excluded "${TGTROOT}/" "${UPLOAD}/"
    else
        echo "ERROR: Unable to sync as rclone is not available or correctly configured" >&2
    fi
fi

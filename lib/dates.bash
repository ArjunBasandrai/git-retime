#!/usr/bin/env bash

grt_parse_offset() {
    local value=${1:-Z}
    case "$value" in
        Z|z|UTC|utc|+00:00|-00:00|+0000|-0000) printf '+0000\t+00:00\n' ;;
        [+-][0-9][0-9]:[0-9][0-9])
            local hour=${value:1:2} minute=${value:4:2}
            ((10#$hour <= 23 && 10#$minute <= 59)) || grt_die "$GRT_EXIT_USAGE" "invalid timezone offset: $value"
            printf '%s\t%s\n' "${value:0:3}${value:4:2}" "$value"
            ;;
        [+-][0-9][0-9][0-9][0-9])
            local hour=${value:1:2} minute=${value:3:2}
            ((10#$hour <= 23 && 10#$minute <= 59)) || grt_die "$GRT_EXIT_USAGE" "invalid timezone offset: $value"
            printf '%s\t%s:%s\n' "$value" "${value:0:3}" "${value:3:2}"
            ;;
        *) grt_die "$GRT_EXIT_USAGE" "timezone must be Z or a fixed offset: $value" ;;
    esac
}

grt_date_to_epoch() {
    local value=$1
    date --date="$value" +%s 2>/dev/null || grt_die "$GRT_EXIT_USAGE" "invalid date: $value"
}

# Prints inclusive-low, inclusive-high, and Git offset.
grt_parse_date_interval() {
    local input=$1 default_zone=${2:-Z}
    local date_part=$input explicit_zone='' zone_git zone_iso precision start next low high

    if [[ $input =~ ^(.*)(Z|z)$ ]]; then
        date_part=${BASH_REMATCH[1]}
        explicit_zone=Z
    elif [[ $input =~ ^(.*)([+-][0-9]{2}:[0-9]{2})$ ]]; then
        date_part=${BASH_REMATCH[1]}
        explicit_zone=${BASH_REMATCH[2]}
    fi

    IFS=$'\t' read -r zone_git zone_iso < <(grt_parse_offset "${explicit_zone:-$default_zone}")

    if [[ $date_part =~ ^([0-9]{4})$ ]]; then
        precision=year
        start="${BASH_REMATCH[1]}-01-01T00:00:00$zone_iso"
        next="$((10#${BASH_REMATCH[1]} + 1))-01-01T00:00:00$zone_iso"
    elif [[ $date_part =~ ^([0-9]{4})-([0-9]{2})$ ]]; then
        precision=month
        start="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-01T00:00:00$zone_iso"
        next=$(date --date="$start +1 month" --iso-8601=seconds 2>/dev/null) || grt_die "$GRT_EXIT_USAGE" "invalid date: $input"
    elif [[ $date_part =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
        precision=day
        start="$date_part"'T00:00:00'"$zone_iso"
        next=$(date --date="$start +1 day" --iso-8601=seconds 2>/dev/null) || grt_die "$GRT_EXIT_USAGE" "invalid date: $input"
    elif [[ $date_part =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2})$ ]]; then
        precision=hour
        start="${BASH_REMATCH[1]}T${BASH_REMATCH[2]}:00:00$zone_iso"
        next=$(date --date="$start +1 hour" --iso-8601=seconds 2>/dev/null) || grt_die "$GRT_EXIT_USAGE" "invalid date: $input"
    elif [[ $date_part =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}):([0-9]{2})$ ]]; then
        precision=minute
        start="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:00$zone_iso"
        next=$(date --date="$start +1 minute" --iso-8601=seconds 2>/dev/null) || grt_die "$GRT_EXIT_USAGE" "invalid date: $input"
    elif [[ $date_part =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        precision=second
        start="$date_part$zone_iso"
        next=$start
    else
        grt_die "$GRT_EXIT_USAGE" "date is not a supported ISO value: $input"
    fi

    low=$(grt_date_to_epoch "$start")
    if [[ $precision == second ]]; then
        high=$low
    else
        high=$(( $(grt_date_to_epoch "$next") - 1 ))
    fi
    printf '%s\t%s\t%s\n' "$low" "$high" "$zone_git"
}

grt_parse_duration() {
    local input=$1 sign=1 rest total=0 number unit
    [[ -n $input ]] || grt_die "$GRT_EXIT_USAGE" 'duration cannot be empty'
    rest=$input
    if [[ $rest == -* ]]; then sign=-1; rest=${rest:1}; elif [[ $rest == +* ]]; then rest=${rest:1}; fi
    [[ -n $rest ]] || grt_die "$GRT_EXIT_USAGE" "invalid duration: $input"
    while [[ -n $rest ]]; do
        if [[ $rest =~ ^([0-9]+)([wdhms])(.*)$ ]]; then
            number=${BASH_REMATCH[1]}
            unit=${BASH_REMATCH[2]}
            rest=${BASH_REMATCH[3]}
            case "$unit" in
                w) total=$((total + 10#$number * 604800)) ;;
                d) total=$((total + 10#$number * 86400)) ;;
                h) total=$((total + 10#$number * 3600)) ;;
                m) total=$((total + 10#$number * 60)) ;;
                s) total=$((total + 10#$number)) ;;
            esac
        else
            grt_die "$GRT_EXIT_USAGE" "invalid duration: $input"
        fi
    done
    printf '%s\n' "$((sign * total))"
}

grt_format_iso() {
    local epoch=$1 offset=$2 offset_iso sign hours minutes shifted direction=1
    if [[ $offset == +0000 || $offset == -0000 ]]; then
        date -u --date="@$epoch" +'%Y-%m-%dT%H:%M:%SZ'
        return
    fi
    sign=${offset:0:1}
    [[ $sign == - ]] && direction=-1
    hours=$((10#${offset:1:2}))
    minutes=$((10#${offset:3:2}))
    shifted=$((epoch + direction * (hours * 3600 + minutes * 60)))
    offset_iso="${offset:0:3}:${offset:3:2}"
    printf '%s%s\n' "$(date -u --date="@$shifted" +'%Y-%m-%dT%H:%M:%S')" "$offset_iso"
}

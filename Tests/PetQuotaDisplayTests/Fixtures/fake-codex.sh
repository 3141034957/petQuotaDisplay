#!/bin/sh
# A local JSON-lines peer: no Codex installation, account, or network is used.
scenario=$1
counter_file=$2
count=0
if [ -f "$counter_file" ]; then
    read -r count < "$counter_file"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"

while IFS= read -r line; do
    # JSONSerialization emits numeric request IDs without whitespace.
    case "$line" in
        *'"id":'*)
            id=${line#*\"id\":}
            id=${id%%[!0-9]*}
            ;;
        *) continue ;;
    esac

    case "$line" in
        *'"initialize"'*)
            if [ "$count" -eq 1 ]; then
                case "$scenario" in
                    initialize-timeout|always-timeout) continue ;;
                    initialize-error)
                        printf '{"id":%s,"error":{"message":"fixture initialization failure"}}\n' "$id"
                        continue
                        ;;
                    initialize-malformed)
                        printf '{"id":%s,"result":null}\n' "$id"
                        continue
                        ;;
                esac
            fi
            if [ "$scenario" = always-timeout ]; then continue; fi
            printf '{"id":%s,"result":{}}\n' "$id"
            ;;
        *refreshToken*)
            if [ "$scenario" = account-timeout ] && [ "$count" -eq 1 ]; then continue; fi
            printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"fixture@example.com","planType":"plus"}}}\n' "$id"
            ;;
        *rateLimits*)
            if [ "$scenario" = quota-timeout ] && [ "$count" -eq 1 ]; then continue; fi
            if [ "$scenario" = unexpected-exit ] && [ "$count" -eq 1 ]; then exit 7; fi
            printf '{"id":%s,"result":{"rateLimits":{"planType":"plus","primary":{"windowDurationMins":10080,"usedPercent":35}}}}\n' "$id"
            ;;
    esac
done

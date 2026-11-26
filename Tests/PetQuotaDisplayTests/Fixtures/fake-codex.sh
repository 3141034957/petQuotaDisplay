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
if [ "$scenario" = ignore-termination ]; then
    trap '' TERM
    printf '%s\n' "$$" > "$counter_file.pid"
fi

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
                    close-stdin)
                        exec 0<&-
                        printf '{"id":%s,"result":{}}\n' "$id"
                        exec /bin/sleep 2
                        ;;
                esac
            fi
            if [ "$scenario" = always-timeout ]; then continue; fi
            printf '{"id":%s,"result":{}}\n' "$id"
            ;;
        *'"account/login/start"'*|*'"account\/login\/start"'*)
            if [ "$scenario" != login-completion ] && [ "$scenario" != login-cancel ]; then exit 8; fi
            printf '{"id":%s,"result":{"type":"chatgpt","loginId":"active-login","authUrl":"https://auth.example.com/login"}}\n' "$id"
            if [ "$scenario" = login-completion ]; then
                printf '{"method":"account/login/completed","params":{"loginId":"old-login","success":false,"error":"fixture old login"}}\n'
                printf '{"method":"account/login/completed","params":{"loginId":"active-login","success":true}}\n'
            fi
            ;;
        *'"account/login/cancel"'*|*'"account\/login\/cancel"'*)
            case "$line" in *'"loginId":"active-login"'*) ;; *) exit 8 ;; esac
            printf '{"method":"account/login/completed","params":{"loginId":"active-login","success":false,"error":"fixture canceled"}}\n'
            printf '{"id":%s,"result":{"status":"canceled"}}\n' "$id"
            ;;
        *refreshToken*)
            if [ "$scenario" = malformed-account-on-refresh ]; then
                account_reads=$((${account_reads:-0} + 1))
                if [ "$account_reads" -gt 1 ]; then
                    printf '{"id":%s,"result":{}}\n' "$id"
                    continue
                fi
            fi
            if [ "$scenario" = login-cancel ]; then
                printf '{"id":%s,"result":{"account":null}}\n' "$id"
                continue
            fi
            if [ "$scenario" = account-timeout ] && [ "$count" -eq 1 ]; then continue; fi
            if [ "$scenario" = sign-out-during-read ] && [ -n "${quota_id:-}" ]; then
                printf '{"id":%s,"result":{"account":null}}\n' "$id"
                printf '{"id":%s,"result":{"rateLimits":{"primary":{"windowDurationMins":10080,"usedPercent":35}}}}\n' "$quota_id"
                printf '{"method":"account/rateLimits/updated"}\n'
                continue
            fi
            if [ "$scenario" = switch-during-read ] && [ -n "${quota_id:-}" ]; then
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"second@example.com","planType":"plus"}}}\n' "$id"
                printf '{"id":%s,"result":{"rateLimits":{"primary":{"windowDurationMins":10080,"usedPercent":35}}}}\n' "$quota_id"
                continue
            fi
            printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"fixture@example.com","planType":"plus"}}}\n' "$id"
            ;;
        *rateLimits*)
            if [ "$scenario" = sign-out-during-read ]; then
                if [ -n "${quota_id:-}" ]; then exit 9; fi
                quota_id=$id
                printf '{"method":"account/updated"}\n'
                continue
            fi
            if [ "$scenario" = switch-during-read ]; then
                if [ -z "${quota_id:-}" ]; then
                    quota_id=$id
                    printf '{"method":"account/updated"}\n'
                else
                    printf '{"id":%s,"result":{"rateLimits":{"primary":{"windowDurationMins":10080,"usedPercent":20}}}}\n' "$id"
                fi
                continue
            fi
            if [ "$scenario" = quota-timeout ] && [ "$count" -eq 1 ]; then continue; fi
            if [ "$scenario" = unexpected-exit ] && [ "$count" -eq 1 ]; then exit 7; fi
            printf '{"id":%s,"result":{"rateLimits":{"planType":"plus","primary":{"windowDurationMins":10080,"usedPercent":35}}}}\n' "$id"
            if [ "$scenario" = ignore-termination ]; then exec /bin/sleep 30; fi
            ;;
    esac
done

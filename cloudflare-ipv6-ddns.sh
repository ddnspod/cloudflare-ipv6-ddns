#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

#进入https://dash.cloudflare.com/profile/api-tokens获取
#（填的是API Token，中文叫API令牌，别填下面的Global API Key，需要授予token DNS修改权限、ZONE和Zone Settings 读权限）
TOKEN="_DCkzF7UoHW0ERx3610ztqEhK7WvJ7H1c_8XXHwy"
#登录cloudflare的邮箱
EMAIL="google@gmail.com"
#区域ID（进入cloudflare，点击对应域名，再点击概述右下侧获取）
ZONE_ID="be92f3a28586eb731ac7cd1568fb1609"
#要解析的域名（www.google.com or google.com）
DOMAIN="www.google.com"

TYPE="AAAA"  # ip类型(A/AAAA)
CDN_PROXIED=false  # 是否开启小黄云cdn加速 （false|关闭 true|开启）
LOG_DIR="$SCRIPT_DIR/$DOMAIN"  # 日志文件存放目录
NOW_IP_FILE="$SCRIPT_DIR/$DOMAIN/$DOMAIN.json"  # 域名解析数据存放目录
DAYS_TO_KEEP=7  # 日志保存天数

# 创建日志目录
create_log_directory() {
  if [ ! -d "$LOG_DIR" ]; then
    mkdir "$LOG_DIR"
  fi
}

# 创建日志文件
create_log_file() {
  local current_date=$(date +"%Y-%m-%d")
  LOG_FILE="$LOG_DIR/${DOMAIN}_${current_date}.log"
  touch "$LOG_FILE"
}

# 获取当前IP地址
get_current_ip() {
  local ip_command=""
  if [ "$TYPE" == "A" ]; then
    ip_command="curl -s -4 https://ip.ddnspod.com -A 'DDnsPod-cf-202312'"
  elif [ "$TYPE" == "AAAA" ]; then
    ip_command="curl -s -6 https://ip.ddnspod.com -A 'DDnsPod-cf-202312'"
  else
    echo "指定的ip类型无效. 请使用 'A' 或者 'AAAA'."
    exit 1
  fi

  $ip_command
}

# 获取域名id
get_domain_id() {
  local response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    -H "X-Auth-Email:$EMAIL" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json")
  local domain_id=$(echo "$response" | jq -r ".result[] | select(.name == \"$DOMAIN\" and .type == \"$TYPE\") | .id")
  echo "$domain_id"
}

# 从JSON文件中读取之前保存的IP地址和域名
get_previous_data() {
  if [ -e "$NOW_IP_FILE" ]; then
    cat "$NOW_IP_FILE"
  else
    echo "{}"
  fi
}

# 写入JSON文件
write_data() {
  local ip="$1"
  local domain="$2"
  echo "{\"ip\":\"$ip\",\"domain\":\"$domain\"}" > "$NOW_IP_FILE"
}

# 写入日志
write_log() {
  local log_message="$1"
  echo "$log_message" >> "$LOG_FILE"
  echo "$log_message"
}

# 清理旧日志，保留最近7天
cleanup_old_logs() {
  # 获取当前时间的时间戳
  current_timestamp=$(date "+%s")

  find "$LOG_DIR" -type f -name "${DOMAIN}_*" -exec basename {} \; | awk -F_ '{print $3}' | while read -r log_date; do
    log_timestamp=$(date -d "$(echo "$log_date" | awk -F. '{print $1}' | awk -F- '{printf "%s-%s-%s", $1, $2, $3}')" "+%s" )
    if [ -n "$log_timestamp" ]; then
      # 计算7天前的时间戳
      cutoff_timestamp=$((current_timestamp - $DAYS_TO_KEEP * 24 * 60 * 60))
      if [ "$log_timestamp" -lt "$cutoff_timestamp" ]; then
        rm -f "$LOG_DIR/${DOMAIN}_${log_date}"
      fi
    fi
  done
}

# 执行一次主要功能
main() {
  create_log_directory

  local IP=$(get_current_ip)
  local PREVIOUS_DATA=$(get_previous_data)
  local PREVIOUS_IP=$(echo "$PREVIOUS_DATA" | jq -r '.ip')
  local PREVIOUS_DOMAIN=$(echo "$PREVIOUS_DATA" | jq -r '.domain')

  #检查当前IP地址是否与之前的相同
  if [ "$IP" == "$PREVIOUS_IP" ] && [ "$DOMAIN" == "$PREVIOUS_DOMAIN" ]; then
    echo "当前IP与域名解析地址相同, 跳过修改操作."
  else
    create_log_file
    DOMAIN_ID=$(get_domain_id)
    # 构建curl命令
    local curl_command="curl -s --location --request PUT 'https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$DOMAIN_ID' \
    --header 'X-Auth-Email: $EMAIL' \
    --header 'Content-Type: application/json' \
    --header 'Authorization: Bearer $TOKEN' \
    --data-raw '{
      \"content\": \"$IP\",
      \"name\": \"$DOMAIN\",
      \"proxied\": $CDN_PROXIED,
      \"type\": \"$TYPE\",
      \"comment\": \"$(date +"%Y-%m-%d %T %Z")\",
      \"ttl\": 60
    }'"

    # 执行curl命令，并将结果保存到变量
    local response=$(eval "$curl_command")
    # 解析JSON数据
    local success=$(echo "$response" | jq -r '.success')

    # 写入日志
    local current_time=$(date +"%Y-%m-%d %T")
    if [ "$success" == "true" ]; then
      local log_message="[$current_time] 修改成功, IP: $IP"
      write_log "$log_message"
      # 保存当前IP地址和域名到JSON文件
      write_data "$IP" "$DOMAIN"
    else
      local errors=$(echo "$response" | jq -r '.errors[]')
      local log_message="[$current_time] 修改失败, 错误: $errors"
      write_log "$log_message"
    fi
  fi

  cleanup_old_logs
  exit
}

main

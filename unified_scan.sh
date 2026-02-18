#!/usr/bin/env bash

set -u

export PATH="$PATH:$HOME/go/bin:$HOME/.local/bin:$HOME/.cargo/bin"

SCRIPT_NAME="$(basename "$0")"

DRY_RUN=0
SKIP_INSTALL=0
OUT_BASE="scan_results"
RESOLVERS_FILE=""
WORDLIST_FILE=""
TARGET_INPUT=""
TARGET_DOMAIN=""
TARGET_URL=""
TARGET_REGEX_ESCAPED=""

OUT_DIR=""
TOOLS_DIR=""
LOG_DIR=""
SUBDOMAIN_DIR=""
RAW_SUBDOMAINS_FILE=""
ALL_SUBDOMAINS_FILE=""
LIVE_SUBDOMAINS_FILE=""
LIVE_HOSTS_FILE=""
DNS_HTTP_REPORT_FILE=""
SUMMARY_FILE=""
AUTO_RESOLVERS_FILE=""
FINAL_RESULTS_FILE=""

APT_UPDATED=0

declare -A TOOL_BINS
declare -A TOOL_STATUS
declare -A TOOL_NEEDS_BINARY
declare -A BIN_CANDIDATES
declare -A INSTALL_COMMANDS

ALL_TOOLS=(
  x8
  httpx
  cloud_enum
  ffuf
  nginx
  parameth
  waybackurls
  linkfinder
  nuclei
  gospider
  metabigor
  sublist3r
  arjun
  cewl
  subfinder
  dnsx
  assetfinder
  github-recon
  katana
  subdomainizer
  shuffledns
)

SUBDOMAIN_TOOLS=(
  assetfinder
  subfinder
  sublist3r
  cloud_enum
  github-recon
  subdomainizer
)

POST_TOOLS=(
  dnsx
  shuffledns
  httpx
  waybackurls
  katana
  gospider
  linkfinder
  parameth
  arjun
  ffuf
  x8
  nuclei
  metabigor
  cewl
  nginx
)

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  printf "[%s] %s\n" "$(timestamp)" "$*"
}

warn() {
  printf "[%s] [WARN] %s\n" "$(timestamp)" "$*" >&2
}

usage() {
  cat <<EOF
Usage: ./$SCRIPT_NAME <target-domain-or-url> [options]

Single command to auto-install (if missing) and run all configured recon tools.

Options:
  -o, --output <dir>      Base output directory (default: scan_results)
  -r, --resolvers <file>  Resolver list for shuffledns
  -w, --wordlist <file>   Wordlist for ffuf
      --skip-install      Do not auto-install missing tools
      --dry-run           Print commands without executing scans/installs
  -h, --help              Show this help

Example:
  ./$SCRIPT_NAME example.com
  ./$SCRIPT_NAME https://example.com --output recon_output --wordlist /usr/share/wordlists/dirb/common.txt
EOF
}

run_as_root() {
  if command -v sudo >/dev/null 2>&1; then
    sudo bash -lc "$*"
  else
    bash -lc "$*"
  fi
}

apt_install() {
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get not available. Install manually: $*"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] apt-get update && apt-get install -y $*"
    return 0
  fi

  if [[ "$APT_UPDATED" -eq 0 ]]; then
    if ! run_as_root "apt-get update"; then
      warn "Failed to run apt-get update"
      return 1
    fi
    APT_UPDATED=1
  fi

  run_as_root "apt-get install -y $*"
}

ensure_prerequisite() {
  local dep="$1"
  if command -v "$dep" >/dev/null 2>&1; then
    return 0
  fi

  case "$dep" in
    go)
      apt_install golang-go
      ;;
    pip3)
      apt_install python3-pip
      ;;
    pipx)
      # pipx avoids PEP-668 / "externally-managed" issues by using venvs
      apt_install pipx python3-venv
      ;;
    cargo)
      # Rust toolchain + common native deps for crates with TLS
      apt_install cargo rustc build-essential pkg-config libssl-dev
      ;;
    git)
      apt_install git
      ;;
    curl)
      apt_install curl
      ;;
    dig)
      apt_install dnsutils
      ;;
    *)
      warn "No installer mapping for prerequisite: $dep"
      return 1
      ;;
  esac
}

resolve_tool_bin() {
  local tool="$1"
  local candidates="${BIN_CANDIDATES[$tool]:-}"
  local candidate
  for candidate in $candidates; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf "%s\n" "$candidate"
      return 0
    fi
  done
  return 1
}

run_install_command() {
  local tool="$1"
  local install_cmd="${INSTALL_COMMANDS[$tool]:-}"
  local install_log="$LOG_DIR/install_${tool}.log"

  if [[ -z "$install_cmd" ]]; then
    warn "No install command configured for $tool"
    return 1
  fi

  case "$install_cmd" in
    go\ install*)
      ensure_prerequisite go || return 1
      ;;
    pipx\ install*)
      ensure_prerequisite pipx || return 1
      ;;
    pip3\ install*|python3\ -m\ pip*)
      ensure_prerequisite pip3 || return 1
      ;;
    cargo\ install*)
      ensure_prerequisite cargo || return 1
      ;;
    apt-get\ install*)
      :
      ;;
  esac

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] $install_cmd"
    return 0
  fi

  if [[ "$install_cmd" == apt-get\ install* ]]; then
    if ! run_as_root "$install_cmd" >>"$install_log" 2>&1; then
      warn "Install failed for $tool (see $install_log)"
      return 1
    fi
  elif [[ "$install_cmd" == pipx\ install* ]]; then
    # pipx sometimes needs git when installing from git+https URLs
    if [[ "$install_cmd" == *git+https://* ]]; then
      ensure_prerequisite git || true
    fi
    if ! bash -lc "$install_cmd" >>"$install_log" 2>&1; then
      # Fallback for environments without pipx or where pipx fails unexpectedly
      # (still try user-level pip and allow Debian/Ubuntu externally-managed override).
      local spec
      spec=""
      # Extract first non-flag argument after: pipx install ...
      # Example: "pipx install --force cloud-enum" => "cloud-enum"
      # Example: "pipx install --force git+https://..." => "git+https://..."
      read -r -a __pipx_parts <<<"$install_cmd"
      for ((i=2; i<${#__pipx_parts[@]}; i++)); do
        if [[ "${__pipx_parts[i]}" == -* ]]; then
          continue
        fi
        spec="${__pipx_parts[i]}"
        break
      done
      unset __pipx_parts
      if [[ -z "$spec" ]]; then
        warn "pipx install failed for $tool and fallback spec parsing failed (see $install_log)"
        return 1
      fi
      warn "pipx install failed for $tool; trying pip --user fallback (see $install_log)"
      ensure_prerequisite pip3 || true
      if ! bash -lc "python3 -m pip install --user --upgrade --break-system-packages $spec" >>"$install_log" 2>&1; then
        warn "Install failed for $tool (see $install_log)"
        return 1
      fi
    fi
  else
    if ! bash -lc "$install_cmd" >>"$install_log" 2>&1; then
      warn "Install failed for $tool (see $install_log)"
      return 1
    fi
  fi

  return 0
}

prepare_tool() {
  local tool="$1"

  if [[ "${TOOL_NEEDS_BINARY[$tool]:-1}" -eq 0 ]]; then
    TOOL_STATUS["$tool"]="ready"
    return 0
  fi

  local found_bin=""
  if found_bin="$(resolve_tool_bin "$tool")"; then
    TOOL_BINS["$tool"]="$found_bin"
    TOOL_STATUS["$tool"]="ready"
    return 0
  fi

  if [[ "$SKIP_INSTALL" -eq 1 ]]; then
    TOOL_STATUS["$tool"]="missing"
    warn "$tool is missing and --skip-install is enabled"
    return 1
  fi

  log "Installing missing tool: $tool"
  if ! run_install_command "$tool"; then
    TOOL_STATUS["$tool"]="missing"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    found_bin="${BIN_CANDIDATES[$tool]%% *}"
    TOOL_BINS["$tool"]="$found_bin"
    TOOL_STATUS["$tool"]="ready"
    return 0
  fi

  if found_bin="$(resolve_tool_bin "$tool")"; then
    TOOL_BINS["$tool"]="$found_bin"
    TOOL_STATUS["$tool"]="ready"
    return 0
  fi

  TOOL_STATUS["$tool"]="missing"
  warn "$tool installation completed but binary is still not found"
  return 1
}

run_capture() {
  local out_file="$1"
  local log_file="$2"
  shift 2

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf -v __cmd "%q " "$@"
    log "[dry-run] ${__cmd% }"
    : >"$out_file"
    : >"$log_file"
    return 0
  fi

  "$@" >"$out_file" 2>"$log_file"
}

run_capture_shell() {
  local out_file="$1"
  local log_file="$2"
  local cmd="$3"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] $cmd"
    : >"$out_file"
    : >"$log_file"
    return 0
  fi

  bash -lc "$cmd" >"$out_file" 2>"$log_file"
}

collect_subdomains_from_file() {
  local src_file="$1"
  [[ -s "$src_file" ]] || return 0

  grep -Eoi "([[:alnum:]-]+\.)+${TARGET_REGEX_ESCAPED}" "$src_file" 2>/dev/null \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/\.$//' \
    >>"$RAW_SUBDOMAINS_FILE" || true
}

build_resolvers_file_if_missing() {
  if [[ -n "$RESOLVERS_FILE" ]]; then
    return 0
  fi

  if [[ -s "$AUTO_RESOLVERS_FILE" ]]; then
    return 0
  fi

  awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | sort -u >"$AUTO_RESOLVERS_FILE"
}

select_wordlist() {
  if [[ -n "$WORDLIST_FILE" && -f "$WORDLIST_FILE" ]]; then
    printf "%s\n" "$WORDLIST_FILE"
    return 0
  fi

  local candidate
  for candidate in \
    /usr/share/seclists/Discovery/Web-Content/common.txt \
    /usr/share/wordlists/dirb/common.txt \
    /usr/share/wordlists/rockyou.txt; do
    if [[ -f "$candidate" ]]; then
      printf "%s\n" "$candidate"
      return 0
    fi
  done

  return 1
}

run_tool() {
  local tool="$1"
  local out_file="$TOOLS_DIR/${tool}.txt"
  local log_file="$LOG_DIR/${tool}.log"
  local bin="${TOOL_BINS[$tool]:-}"
  local resolver_file=""
  local wl=""
  local keyword=""

  : >"$out_file"
  : >"$log_file"

  case "$tool" in
    assetfinder)
      run_capture "$out_file" "$log_file" "$bin" --subs-only "$TARGET_DOMAIN"
      ;;
    subfinder)
      run_capture "$out_file" "$log_file" "$bin" -d "$TARGET_DOMAIN" -silent \
        || run_capture "$out_file" "$log_file" "$bin" -d "$TARGET_DOMAIN"
      ;;
    sublist3r)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] $bin -d $TARGET_DOMAIN -o $out_file -n"
        return 0
      fi
      "$bin" -d "$TARGET_DOMAIN" -o "$out_file" -n >"$log_file" 2>&1 \
        || "$bin" -d "$TARGET_DOMAIN" -o "$out_file" >"$log_file" 2>&1
      ;;
    cloud_enum)
      keyword="${TARGET_DOMAIN%%.*}"
      run_capture "$out_file" "$log_file" "$bin" -k "$keyword" \
        || run_capture "$out_file" "$log_file" "$bin" -k "$TARGET_DOMAIN"
      ;;
    github-recon)
      run_capture "$out_file" "$log_file" "$bin" -d "$TARGET_DOMAIN" \
        || run_capture "$out_file" "$log_file" "$bin" "$TARGET_DOMAIN"
      ;;
    subdomainizer)
      run_capture "$out_file" "$log_file" "$bin" -u "$TARGET_URL" \
        || run_capture "$out_file" "$log_file" "$bin" -d "$TARGET_DOMAIN"
      ;;
    dnsx)
      run_capture "$out_file" "$log_file" "$bin" -l "$ALL_SUBDOMAINS_FILE" -a -resp -silent \
        || run_capture "$out_file" "$log_file" "$bin" -l "$ALL_SUBDOMAINS_FILE" -silent
      ;;
    shuffledns)
      resolver_file="$RESOLVERS_FILE"
      if [[ -z "$resolver_file" ]]; then
        resolver_file="$AUTO_RESOLVERS_FILE"
      fi
      if [[ -s "$resolver_file" ]]; then
        run_capture "$out_file" "$log_file" "$bin" -d "$TARGET_DOMAIN" -list "$ALL_SUBDOMAINS_FILE" -r "$resolver_file" -silent \
          || run_capture "$out_file" "$log_file" "$bin" -d "$TARGET_DOMAIN" -list "$ALL_SUBDOMAINS_FILE" -r "$resolver_file"
      else
        run_capture "$out_file" "$log_file" "$bin" -d "$TARGET_DOMAIN" -list "$ALL_SUBDOMAINS_FILE" -silent \
          || run_capture "$out_file" "$log_file" "$bin" -d "$TARGET_DOMAIN" -list "$ALL_SUBDOMAINS_FILE"
      fi
      ;;
    httpx)
      run_capture "$out_file" "$log_file" "$bin" -l "$ALL_SUBDOMAINS_FILE" -silent -status-code -title -tech-detect \
        || run_capture "$out_file" "$log_file" "$bin" -l "$ALL_SUBDOMAINS_FILE" -silent
      ;;
    waybackurls)
      run_capture_shell "$out_file" "$log_file" "\"$bin\" < \"$ALL_SUBDOMAINS_FILE\""
      ;;
    katana)
      if [[ -s "$LIVE_HOSTS_FILE" ]]; then
        run_capture "$out_file" "$log_file" "$bin" -list "$LIVE_HOSTS_FILE" -silent \
          || run_capture "$out_file" "$log_file" "$bin" -list "$LIVE_HOSTS_FILE"
      else
        run_capture "$out_file" "$log_file" "$bin" -u "$TARGET_URL" -silent \
          || run_capture "$out_file" "$log_file" "$bin" -u "$TARGET_URL"
      fi
      ;;
    gospider)
      if [[ -s "$LIVE_HOSTS_FILE" ]]; then
        run_capture "$out_file" "$log_file" "$bin" -S "$LIVE_HOSTS_FILE" -q \
          || run_capture "$out_file" "$log_file" "$bin" -S "$LIVE_HOSTS_FILE"
      else
        run_capture "$out_file" "$log_file" "$bin" -s "$TARGET_URL" -q \
          || run_capture "$out_file" "$log_file" "$bin" -s "$TARGET_URL"
      fi
      ;;
    linkfinder)
      run_capture "$out_file" "$log_file" "$bin" -i "$TARGET_URL" -o cli \
        || run_capture_shell "$out_file" "$log_file" "python3 \"$(command -v "$bin")\" -i \"$TARGET_URL\" -o cli"
      ;;
    parameth)
      run_capture "$out_file" "$log_file" "$bin" -u "$TARGET_URL" \
        || run_capture "$out_file" "$log_file" "$bin" -d "$TARGET_DOMAIN" \
        || run_capture "$out_file" "$log_file" "$bin" "$TARGET_URL"
      ;;
    arjun)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] $bin -u $TARGET_URL --get -oT $out_file"
        return 0
      fi
      "$bin" -u "$TARGET_URL" --get -oT "$out_file" >"$log_file" 2>&1 \
        || "$bin" -u "$TARGET_URL" -oT "$out_file" >"$log_file" 2>&1
      ;;
    ffuf)
      if ! wl="$(select_wordlist)"; then
        warn "No wordlist found for ffuf, skipping"
        return 2
      fi
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] $bin -w $wl -u ${TARGET_URL%/}/FUZZ -mc all -of json -o $out_file"
        return 0
      fi
      "$bin" -w "$wl" -u "${TARGET_URL%/}/FUZZ" -mc all -of json -o "$out_file" >"$log_file" 2>&1 \
        || "$bin" -w "$wl" -u "${TARGET_URL%/}/FUZZ" -mc all -of csv -o "$out_file" >"$log_file" 2>&1
      ;;
    x8)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] $bin -u $TARGET_URL -o $out_file"
        return 0
      fi
      "$bin" -u "$TARGET_URL" -o "$out_file" >"$log_file" 2>&1 \
        || "$bin" --url "$TARGET_URL" >"$out_file" 2>"$log_file"
      ;;
    nuclei)
      if [[ -s "$LIVE_HOSTS_FILE" ]]; then
        run_capture "$out_file" "$log_file" "$bin" -l "$LIVE_HOSTS_FILE" -silent \
          || run_capture "$out_file" "$log_file" "$bin" -l "$LIVE_HOSTS_FILE"
      else
        run_capture "$out_file" "$log_file" "$bin" -u "$TARGET_URL" -silent \
          || run_capture "$out_file" "$log_file" "$bin" -u "$TARGET_URL"
      fi
      ;;
    metabigor)
      run_capture "$out_file" "$log_file" "$bin" net --org "$TARGET_DOMAIN" \
        || run_capture "$out_file" "$log_file" "$bin" domain "$TARGET_DOMAIN"
      ;;
    cewl)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] $bin $TARGET_URL -d 2 -w $out_file"
        return 0
      fi
      "$bin" "$TARGET_URL" -d 2 -w "$out_file" >"$log_file" 2>&1
      ;;
    nginx)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] curl -ksI $TARGET_URL | awk '/^Server:/ {print \$0}'"
        return 0
      fi
      curl -ksI "$TARGET_URL" | awk 'tolower($1) == "server:" {print $0}' >"$out_file" 2>"$log_file" || true
      ;;
    *)
      warn "No run mapping for tool: $tool"
      return 1
      ;;
  esac
}

build_dns_http_report() {
  ensure_prerequisite dig || true
  ensure_prerequisite curl || true

  {
    printf "%-35s | %-12s | %-15s | %-6s | %-6s\n" "SUBDOMAIN" "DNS STATUS" "IP ADDRESS" "HTTP" "HTTPS"
    echo "------------------------------------------------------------------------------------------------------"
  } >"$DNS_HTTP_REPORT_FILE"

  : >"$LIVE_SUBDOMAINS_FILE"
  : >"$LIVE_HOSTS_FILE"

  while IFS= read -r subdomain || [[ -n "$subdomain" ]]; do
    [[ -z "$subdomain" ]] && continue

    local dig_output dns_status ip_address http_code https_code
    dig_output="$(dig +nocmd "$subdomain" A +noall +comments +answer 2>/dev/null || true)"
    dns_status="$(printf "%s\n" "$dig_output" | awk -F'status: ' '/status:/ {print $2; exit}' | awk -F',' '{print $1}')"
    ip_address="$(printf "%s\n" "$dig_output" | awk '/IN[[:space:]]+A/ {print $5; exit}')"

    [[ -z "$dns_status" ]] && dns_status="TIMEOUT"
    [[ -z "$ip_address" ]] && ip_address="N/A"

    http_code="$(curl -o /dev/null -s -L -w "%{http_code}" --max-time 5 "http://$subdomain" || true)"
    https_code="$(curl -o /dev/null -s -k -L -w "%{http_code}" --max-time 5 "https://$subdomain" || true)"

    [[ -z "$http_code" ]] && http_code="000"
    [[ -z "$https_code" ]] && https_code="000"

    printf "%-35s | %-12s | %-15s | %-6s | %-6s\n" "$subdomain" "$dns_status" "$ip_address" "$http_code" "$https_code" >>"$DNS_HTTP_REPORT_FILE"

    if [[ "$dns_status" == "NOERROR" ]]; then
      printf "%s\n" "$subdomain" >>"$LIVE_SUBDOMAINS_FILE"
      if [[ "$https_code" != "000" ]]; then
        printf "https://%s\n" "$subdomain" >>"$LIVE_HOSTS_FILE"
      elif [[ "$http_code" != "000" ]]; then
        printf "http://%s\n" "$subdomain" >>"$LIVE_HOSTS_FILE"
      fi
    fi
  done <"$ALL_SUBDOMAINS_FILE"

  sort -u "$LIVE_SUBDOMAINS_FILE" -o "$LIVE_SUBDOMAINS_FILE"
  sort -u "$LIVE_HOSTS_FILE" -o "$LIVE_HOSTS_FILE"
}

write_summary() {
  local tool
  {
    echo "Target input: $TARGET_INPUT"
    echo "Target domain: $TARGET_DOMAIN"
    echo "Output directory: $OUT_DIR"
    echo
    echo "Tool status:"
    for tool in "${ALL_TOOLS[@]}"; do
      printf "  - %-13s : %s\n" "$tool" "${TOOL_STATUS[$tool]:-unknown}"
    done
    echo
    echo "Artifacts:"
    echo "  - All subdomains: $ALL_SUBDOMAINS_FILE ($(wc -l <"$ALL_SUBDOMAINS_FILE" 2>/dev/null || echo 0) lines)"
    echo "  - Live subdomains: $LIVE_SUBDOMAINS_FILE ($(wc -l <"$LIVE_SUBDOMAINS_FILE" 2>/dev/null || echo 0) lines)"
    echo "  - Live hosts: $LIVE_HOSTS_FILE ($(wc -l <"$LIVE_HOSTS_FILE" 2>/dev/null || echo 0) lines)"
    echo "  - DNS/HTTP report: $DNS_HTTP_REPORT_FILE"
  } >"$SUMMARY_FILE"
}

init_mappings() {
  TOOL_NEEDS_BINARY["nginx"]=0

  BIN_CANDIDATES["x8"]="x8"
  BIN_CANDIDATES["httpx"]="httpx"
  BIN_CANDIDATES["cloud_enum"]="cloud_enum cloud_enum.py"
  BIN_CANDIDATES["ffuf"]="ffuf"
  BIN_CANDIDATES["parameth"]="parameth"
  BIN_CANDIDATES["waybackurls"]="waybackurls"
  BIN_CANDIDATES["linkfinder"]="linkfinder linkfinder.py"
  BIN_CANDIDATES["nuclei"]="nuclei"
  BIN_CANDIDATES["gospider"]="gospider"
  BIN_CANDIDATES["metabigor"]="metabigor"
  BIN_CANDIDATES["sublist3r"]="sublist3r"
  BIN_CANDIDATES["arjun"]="arjun"
  BIN_CANDIDATES["cewl"]="cewl"
  BIN_CANDIDATES["subfinder"]="subfinder"
  BIN_CANDIDATES["dnsx"]="dnsx"
  BIN_CANDIDATES["assetfinder"]="assetfinder"
  BIN_CANDIDATES["github-recon"]="github-recon githubrecon"
  BIN_CANDIDATES["katana"]="katana"
  BIN_CANDIDATES["subdomainizer"]="subdomainizer subdomainizer.py"
  BIN_CANDIDATES["shuffledns"]="shuffledns"

  INSTALL_COMMANDS["x8"]="cargo install x8"
  INSTALL_COMMANDS["httpx"]="go install github.com/projectdiscovery/httpx/cmd/httpx@latest"
  INSTALL_COMMANDS["cloud_enum"]="pipx install --force cloud-enum"
  INSTALL_COMMANDS["ffuf"]="go install github.com/ffuf/ffuf/v2@latest"
  INSTALL_COMMANDS["parameth"]="pipx install --force parameth"
  INSTALL_COMMANDS["waybackurls"]="go install github.com/tomnomnom/waybackurls@latest"
  # LinkFinder packaging varies; pipx is safer than system pip.
  INSTALL_COMMANDS["linkfinder"]="pipx install --force linkfinder"
  INSTALL_COMMANDS["nuclei"]="go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
  INSTALL_COMMANDS["gospider"]="go install github.com/jaeles-project/gospider@latest"
  INSTALL_COMMANDS["metabigor"]="go install github.com/j3ssie/metabigor@latest"
  INSTALL_COMMANDS["sublist3r"]="pipx install --force sublist3r"
  INSTALL_COMMANDS["arjun"]="pipx install --force arjun"
  INSTALL_COMMANDS["cewl"]="apt-get install -y cewl"
  INSTALL_COMMANDS["subfinder"]="go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
  INSTALL_COMMANDS["dnsx"]="go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest"
  INSTALL_COMMANDS["assetfinder"]="go install github.com/tomnomnom/assetfinder@latest"
  INSTALL_COMMANDS["github-recon"]="pipx install --force git+https://github.com/gwen001/github-recon.git"
  INSTALL_COMMANDS["katana"]="go install github.com/projectdiscovery/katana/cmd/katana@latest"
  INSTALL_COMMANDS["subdomainizer"]="pipx install --force subdomainizer"
  INSTALL_COMMANDS["shuffledns"]="go install github.com/projectdiscovery/shuffledns/cmd/shuffledns@latest"
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--output)
        [[ $# -ge 2 ]] || { warn "Missing value for $1"; exit 1; }
        OUT_BASE="$2"
        shift 2
        ;;
      -r|--resolvers)
        [[ $# -ge 2 ]] || { warn "Missing value for $1"; exit 1; }
        RESOLVERS_FILE="$2"
        shift 2
        ;;
      -w|--wordlist)
        [[ $# -ge 2 ]] || { warn "Missing value for $1"; exit 1; }
        WORDLIST_FILE="$2"
        shift 2
        ;;
      --skip-install)
        SKIP_INSTALL=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        warn "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        if [[ -z "$TARGET_INPUT" ]]; then
          TARGET_INPUT="$1"
          shift
        else
          warn "Only one target is supported. Unexpected argument: $1"
          exit 1
        fi
        ;;
    esac
  done

  if [[ -z "$TARGET_INPUT" ]]; then
    warn "Target is required"
    usage
    exit 1
  fi
}

prepare_target() {
  TARGET_DOMAIN="$TARGET_INPUT"
  TARGET_DOMAIN="${TARGET_DOMAIN#http://}"
  TARGET_DOMAIN="${TARGET_DOMAIN#https://}"
  TARGET_DOMAIN="${TARGET_DOMAIN%%/*}"
  TARGET_DOMAIN="${TARGET_DOMAIN%%:*}"
  TARGET_DOMAIN="$(printf "%s" "$TARGET_DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)"

  if [[ -z "$TARGET_DOMAIN" ]]; then
    warn "Could not parse target domain from input: $TARGET_INPUT"
    exit 1
  fi

  if [[ "$TARGET_INPUT" =~ ^https?:// ]]; then
    TARGET_URL="${TARGET_INPUT%%/}"
  else
    TARGET_URL="https://$TARGET_DOMAIN"
  fi

  TARGET_REGEX_ESCAPED="$(printf "%s" "$TARGET_DOMAIN" | sed -E 's/[][(){}.^$*+?|\\/]/\\&/g')"
}

prepare_output_paths() {
  local safe_target timestamp_suffix
  safe_target="$(printf "%s" "$TARGET_DOMAIN" | sed -E 's/[^[:alnum:]._-]+/_/g')"
  timestamp_suffix="$(date +%Y%m%d_%H%M%S)"

  OUT_DIR="$OUT_BASE/${safe_target}_${timestamp_suffix}"
  TOOLS_DIR="$OUT_DIR/tools"
  LOG_DIR="$OUT_DIR/logs"
  SUBDOMAIN_DIR="$OUT_DIR/subdomains"

  RAW_SUBDOMAINS_FILE="$SUBDOMAIN_DIR/all_subdomains_raw.txt"
  ALL_SUBDOMAINS_FILE="$SUBDOMAIN_DIR/all_subdomains.txt"
  LIVE_SUBDOMAINS_FILE="$SUBDOMAIN_DIR/live_subdomains.txt"
  LIVE_HOSTS_FILE="$SUBDOMAIN_DIR/live_hosts.txt"
  DNS_HTTP_REPORT_FILE="$OUT_DIR/dns_http_report.txt"
  SUMMARY_FILE="$OUT_DIR/summary.txt"
  FINAL_RESULTS_FILE="$OUT_DIR/final_results.txt"
  AUTO_RESOLVERS_FILE="$OUT_DIR/resolvers_auto.txt"

  mkdir -p "$OUT_DIR" "$TOOLS_DIR" "$LOG_DIR" "$SUBDOMAIN_DIR"
  : >"$RAW_SUBDOMAINS_FILE"
  : >"$ALL_SUBDOMAINS_FILE"
  : >"$LIVE_SUBDOMAINS_FILE"
  : >"$LIVE_HOSTS_FILE"
}

scan_subdomains() {
  local tool out_file
  for tool in "${SUBDOMAIN_TOOLS[@]}"; do
    if [[ "${TOOL_STATUS[$tool]:-missing}" != "ready" ]]; then
      warn "Skipping $tool because it is unavailable"
      continue
    fi

    log "Running $tool..."
    if run_tool "$tool"; then
      TOOL_STATUS["$tool"]="success"
      out_file="$TOOLS_DIR/${tool}.txt"
      collect_subdomains_from_file "$out_file"
    else
      TOOL_STATUS["$tool"]="failed"
      warn "$tool failed (see $LOG_DIR/${tool}.log)"
    fi
  done

  sort -u "$RAW_SUBDOMAINS_FILE" >"$ALL_SUBDOMAINS_FILE" || true

  if [[ ! -s "$ALL_SUBDOMAINS_FILE" ]]; then
    printf "%s\n" "$TARGET_DOMAIN" >"$ALL_SUBDOMAINS_FILE"
    warn "No subdomains discovered by tools, using target domain only"
  fi
}

scan_post_tools() {
  local tool rc
  for tool in "${POST_TOOLS[@]}"; do
    if [[ "${TOOL_STATUS[$tool]:-missing}" != "ready" && "$tool" != "nginx" ]]; then
      warn "Skipping $tool because it is unavailable"
      continue
    fi

    log "Running $tool..."
    if run_tool "$tool"; then
      TOOL_STATUS["$tool"]="success"
    else
      rc=$?
      if [[ "$rc" -eq 2 ]]; then
        TOOL_STATUS["$tool"]="skipped"
      else
        TOOL_STATUS["$tool"]="failed"
      fi
      warn "$tool failed/skipped (see $LOG_DIR/${tool}.log)"
    fi
  done
}

write_final_results() {
  local tool out_file log_file status lines bytes

  {
    echo "Unified Scan - Final Results"
    echo "============================"
    echo "Target input : $TARGET_INPUT"
    echo "Target domain: $TARGET_DOMAIN"
    echo "Target URL   : $TARGET_URL"
    echo "Output dir   : $OUT_DIR"
    echo
    echo "Key artifacts:"
    echo "  - All subdomains : $ALL_SUBDOMAINS_FILE"
    echo "  - Live subdomains: $LIVE_SUBDOMAINS_FILE"
    echo "  - Live hosts     : $LIVE_HOSTS_FILE"
    echo "  - DNS/HTTP report: $DNS_HTTP_REPORT_FILE"
    echo
    echo "Counts:"
    echo "  - all_subdomains : $(wc -l <"$ALL_SUBDOMAINS_FILE" 2>/dev/null || echo 0)"
    echo "  - live_subdomains: $(wc -l <"$LIVE_SUBDOMAINS_FILE" 2>/dev/null || echo 0)"
    echo "  - live_hosts     : $(wc -l <"$LIVE_HOSTS_FILE" 2>/dev/null || echo 0)"
    echo
    echo "Per-tool results (status + output/log paths):"
    for tool in "${ALL_TOOLS[@]}"; do
      out_file="$TOOLS_DIR/${tool}.txt"
      log_file="$LOG_DIR/${tool}.log"
      status="${TOOL_STATUS[$tool]:-unknown}"
      lines="0"
      bytes="0"
      if [[ -f "$out_file" ]]; then
        lines="$(wc -l <"$out_file" 2>/dev/null || echo 0)"
        bytes="$(wc -c <"$out_file" 2>/dev/null || echo 0)"
      fi
      printf "  - %-13s : %-8s | %s lines | %s bytes | out=%s | log=%s\n" \
        "$tool" "$status" "$lines" "$bytes" "$out_file" "$log_file"

      # If install failed, point to install log explicitly
      if [[ "$status" == "missing" && -f "$LOG_DIR/install_${tool}.log" ]]; then
        printf "                 install_log=%s\n" "$LOG_DIR/install_${tool}.log"
      fi
    done
  } >"$FINAL_RESULTS_FILE"
}

main() {
  local tool

  parse_args "$@"
  init_mappings
  prepare_target
  prepare_output_paths

  log "Target: $TARGET_DOMAIN"
  log "Output directory: $OUT_DIR"

  if [[ -n "$RESOLVERS_FILE" && ! -f "$RESOLVERS_FILE" ]]; then
    warn "Resolver file does not exist: $RESOLVERS_FILE"
    exit 1
  fi

  if [[ -n "$WORDLIST_FILE" && ! -f "$WORDLIST_FILE" ]]; then
    warn "Wordlist file does not exist: $WORDLIST_FILE"
    exit 1
  fi

  for tool in "${ALL_TOOLS[@]}"; do
    TOOL_STATUS["$tool"]="pending"
  done

  log "Checking and installing missing tools..."
  for tool in "${ALL_TOOLS[@]}"; do
    prepare_tool "$tool" || true
  done

  build_resolvers_file_if_missing

  log "Starting subdomain discovery tools..."
  scan_subdomains

  log "Building DNS/HTTP live host report..."
  build_dns_http_report

  log "Running remaining tools sequentially..."
  scan_post_tools

  write_summary
  write_final_results

  log "Scan complete."
  log "Summary: $SUMMARY_FILE"
  log "Final results: $FINAL_RESULTS_FILE"
}

main "$@"

#!/usr/bin/env bash

# ============================================================
# Native Apache JMeter Installer
# Target OS: Ubuntu 24.04
#
# Installs:
#   - OpenJDK 17
#   - Apache JMeter 5.6.3
#
# No Docker is used.
# ============================================================

set -Eeuo pipefail


# ============================================================
# ROOT CHECK
# ============================================================

if [[ ${EUID} -ne 0 ]]; then
    echo "Run this installer with elevated privileges."
    exit 1
fi


export DEBIAN_FRONTEND=noninteractive


# ============================================================
# VARIABLES
# ============================================================

JMETER_VERSION="${JMETER_VERSION:-5.6.3}"

JMETER_ARCHIVE="apache-jmeter-${JMETER_VERSION}.tgz"

JMETER_BASE_URL="https://dlcdn.apache.org/jmeter/binaries"

JMETER_DOWNLOAD_URL="${JMETER_BASE_URL}/${JMETER_ARCHIVE}"

JMETER_CHECKSUM_URL="${JMETER_DOWNLOAD_URL}.sha512"

JMETER_INSTALL_DIR="/opt/apache-jmeter-${JMETER_VERSION}"

JMETER_LINK="/opt/jmeter"

JMETER_TESTS_DIR="/opt/jmeter-tests"

JMETER_RESULTS_DIR="/opt/jmeter-results"

JMETER_LOGS_DIR="/opt/jmeter-logs"

INSTALL_LOG="/var/log/jmeter-install.log"

TEMP_DIR=""


# ============================================================
# HELPER FUNCTIONS
# ============================================================

log() {
    printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}


warn() {
    printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2
}


fail() {
    printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
    exit 1
}


cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}


on_error() {
    local exit_code=$?
    local line_number="${1:-unknown}"

    echo
    echo "JMeter installation failed."
    echo "Line: ${line_number}"
    echo "Exit code: ${exit_code}"
    echo
    echo "Installation log:"
    echo
    echo "${INSTALL_LOG}"
    echo

    exit "$exit_code"
}


trap 'on_error $LINENO' ERR

trap cleanup EXIT


# ============================================================
# INSTALLATION LOG
# ============================================================

touch "$INSTALL_LOG"

chmod 0600 "$INSTALL_LOG"

exec > >(tee -a "$INSTALL_LOG") 2>&1


# ============================================================
# STEP 1 - VERIFY OPERATING SYSTEM
# ============================================================

log "Checking operating system"

[[ -r /etc/os-release ]] ||
    fail "/etc/os-release does not exist."

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] ||
    fail "This installer supports Ubuntu only."

echo "Operating system: ${PRETTY_NAME}"

echo "Architecture: $(dpkg --print-architecture)"

echo "JMeter version: ${JMETER_VERSION}"

echo "Installation log: ${INSTALL_LOG}"

if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    warn "This installer was designed for Ubuntu 24.04."
    warn "Detected Ubuntu version: ${VERSION_ID:-unknown}"
fi


# ============================================================
# STEP 2 - CHECK SYSTEM RESOURCES
# ============================================================

log "Checking system resources"

CPU_COUNT="$(nproc)"

MEMORY_MB="$(
    awk '/MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo
)"

ROOT_FREE_MB="$(
    df --output=avail -BM / |
        tail -n 1 |
        tr -dc '0-9'
)"

echo "CPU count: ${CPU_COUNT}"

echo "Memory: ${MEMORY_MB} MB"

echo "Root filesystem available: ${ROOT_FREE_MB} MB"

if (( CPU_COUNT < 2 )); then
    warn "At least 2 CPU cores are recommended."
fi

if (( MEMORY_MB < 6000 )); then
    warn "The VM has less than 6 GB RAM."
fi

if (( ROOT_FREE_MB < 5000 )); then
    fail "At least 5 GB of free root filesystem space is required."
fi


# ============================================================
# STEP 3 - INSTALL PREREQUISITES
# ============================================================

log "Installing Java and required packages"

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    openjdk-17-jre-headless \
    tar


# ============================================================
# STEP 4 - VERIFY JAVA
# ============================================================

log "Verifying Java"

java -version

JAVA_MAJOR_VERSION="$(
    java -version 2>&1 |
        awk -F '"' '/version/ {print $2}' |
        awk -F '.' '{print $1}'
)"

if [[ -z "$JAVA_MAJOR_VERSION" ]]; then
    fail "Unable to determine the Java version."
fi

if (( JAVA_MAJOR_VERSION < 8 )); then
    fail "Apache JMeter requires Java 8 or later."
fi

echo "Detected Java major version: ${JAVA_MAJOR_VERSION}"


# ============================================================
# STEP 5 - CHECK APACHE DOWNLOAD ACCESS
# ============================================================

log "Checking Apache download access"

curl \
    -fsSI \
    --max-time 20 \
    "$JMETER_DOWNLOAD_URL" \
    >/dev/null ||
    fail "Cannot reach ${JMETER_DOWNLOAD_URL}"

curl \
    -fsSI \
    --max-time 20 \
    "$JMETER_CHECKSUM_URL" \
    >/dev/null ||
    fail "Cannot reach ${JMETER_CHECKSUM_URL}"

echo "Apache JMeter download: reachable"

echo "Apache JMeter checksum: reachable"


# ============================================================
# STEP 6 - DOWNLOAD AND INSTALL JMETER
# ============================================================

if [[ -x "${JMETER_INSTALL_DIR}/bin/jmeter" ]]; then

    log "Apache JMeter ${JMETER_VERSION} is already installed"

else

    log "Downloading Apache JMeter ${JMETER_VERSION}"

    TEMP_DIR="$(mktemp -d)"

    cd "$TEMP_DIR"

    curl \
        -fL \
        --retry 3 \
        --retry-delay 2 \
        "$JMETER_DOWNLOAD_URL" \
        -o "$JMETER_ARCHIVE"

    curl \
        -fL \
        --retry 3 \
        --retry-delay 2 \
        "$JMETER_CHECKSUM_URL" \
        -o "${JMETER_ARCHIVE}.sha512"


    log "Verifying JMeter SHA-512 checksum"

    EXPECTED_CHECKSUM="$(
        awk '{print $1}' "${JMETER_ARCHIVE}.sha512"
    )"

    ACTUAL_CHECKSUM="$(
        sha512sum "$JMETER_ARCHIVE" |
            awk '{print $1}'
    )"

    if [[ -z "$EXPECTED_CHECKSUM" ]]; then
        fail "Unable to read the expected JMeter checksum."
    fi

    if [[ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]]; then
        echo "Expected checksum: ${EXPECTED_CHECKSUM}"
        echo "Actual checksum:   ${ACTUAL_CHECKSUM}"

        fail "JMeter SHA-512 checksum verification failed."
    fi

    echo "SHA-512 checksum verification passed."


    log "Extracting Apache JMeter"

    tar \
        -xzf \
        "$JMETER_ARCHIVE"


    [[ -d "apache-jmeter-${JMETER_VERSION}" ]] ||
        fail "The extracted JMeter directory was not found."


    log "Installing Apache JMeter"

    rm \
        -rf \
        "$JMETER_INSTALL_DIR"

    mv \
        "apache-jmeter-${JMETER_VERSION}" \
        "$JMETER_INSTALL_DIR"

fi


# ============================================================
# STEP 7 - CREATE SYMBOLIC LINKS
# ============================================================

log "Creating stable JMeter symbolic links"

ln \
    -sfn \
    "$JMETER_INSTALL_DIR" \
    "$JMETER_LINK"

ln \
    -sfn \
    "${JMETER_LINK}/bin/jmeter" \
    /usr/local/bin/jmeter


# ============================================================
# STEP 8 - CREATE WORKING DIRECTORIES
# ============================================================

log "Creating JMeter working directories"

install \
    -d \
    -m 0755 \
    "$JMETER_TESTS_DIR" \
    "$JMETER_RESULTS_DIR" \
    "$JMETER_LOGS_DIR"


# ============================================================
# STEP 9 - CONFIGURE ENVIRONMENT
# ============================================================

log "Creating JMeter environment configuration"

cat > /etc/profile.d/jmeter.sh <<'EOF'
export JMETER_HOME="/opt/jmeter"
export PATH="${JMETER_HOME}/bin:${PATH}"
EOF

chmod \
    0644 \
    /etc/profile.d/jmeter.sh


# ============================================================
# STEP 10 - CONFIGURE JAVA HEAP
# ============================================================

log "Creating conservative JMeter heap configuration"

cat > "${JMETER_INSTALL_DIR}/bin/setenv.sh" <<'EOF'
#!/usr/bin/env bash

# Conservative settings because this VM also runs the
# observability stack.
export HEAP="-Xms512m -Xmx1024m -XX:MaxMetaspaceSize=256m"

# Use the G1 garbage collector.
export JVM_ARGS="-XX:+UseG1GC"
EOF

chmod \
    0755 \
    "${JMETER_INSTALL_DIR}/bin/setenv.sh"


# ============================================================
# STEP 11 - VALIDATE INSTALLATION
# ============================================================

log "Validating Apache JMeter installation"

command -v jmeter >/dev/null 2>&1 ||
    fail "The jmeter command was not added to the system path."

[[ -x "${JMETER_INSTALL_DIR}/bin/jmeter" ]] ||
    fail "The JMeter executable was not installed."

jmeter --version


# ============================================================
# STEP 12 - INSTALLATION SUMMARY
# ============================================================

log "Installation summary"

cat <<EOF

============================================================
APACHE JMETER INSTALLATION COMPLETED
============================================================

JMeter version:

    ${JMETER_VERSION}

Java version:

    ${JAVA_MAJOR_VERSION}

JMeter installation:

    ${JMETER_INSTALL_DIR}

Stable JMeter path:

    ${JMETER_LINK}

JMeter command:

    /usr/local/bin/jmeter

Test plans directory:

    ${JMETER_TESTS_DIR}

Test results directory:

    ${JMETER_RESULTS_DIR}

JMeter logs directory:

    ${JMETER_LOGS_DIR}

Installation log:

    ${INSTALL_LOG}


Verify JMeter:

    jmeter --version


Important:

    Use the JMeter GUI only for creating or debugging tests.

    Run actual load tests using CLI mode.

    Start with a small number of users because this VM also
    runs Grafana, Prometheus, Loki, Tempo and Alloy.

============================================================

EOF

exit 0
``
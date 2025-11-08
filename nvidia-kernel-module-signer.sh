#!/bin/bash
#
# NVIDIA Secure Boot Driver Signing Automation Script
# This version detects driver info from filesystem
#
# Usage: sudo bash nvidia-secure-boot-sign.sh
#

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
MOK_DIR="/var/lib/shim-signed/mok"
MOK_PRIV="$MOK_DIR/MOK.priv"
MOK_DER="$MOK_DIR/MOK.der"
MOK_PEM="$MOK_DIR/MOK.pem"
KERNEL_VERSION=$(uname -r)
DKMS_CONFIG="/etc/dkms/framework.conf"

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to detect NVIDIA driver version from filesystem
detect_nvidia_driver_version() {
    local version=""
    
    # Method 1: Try to find from DKMS installation directory
    if [ -d "/var/lib/dkms/nvidia" ]; then
        # Get most recent version from DKMS
        version=$(ls -1d /var/lib/dkms/nvidia/*/ 2>/dev/null | grep -oP '(?<=/nvidia/)[^/]+' | sort -V | tail -1)
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    fi
    
    # Method 2: Try from installed kernel modules
    if find /lib/modules -name "nvidia.ko*" -o -name "nvidia-modeset.ko*" 2>/dev/null | grep -q .; then
        # Find one module and get its version
        local module=$(find /lib/modules -name "nvidia.ko*" -o -name "nvidia-modeset.ko*" 2>/dev/null | head -1)
        if [ -n "$module" ]; then
            # Decompress if needed
            local temp_module="$module"
            if [[ "$module" == *.zst ]]; then
                temp_module="/tmp/nvidia_temp_$(date +%s).ko"
                zstd -d "$module" -o "$temp_module" --force 2>/dev/null
            elif [[ "$module" == *.xz ]]; then
                temp_module="/tmp/nvidia_temp_$(date +%s).ko"
                xz -d -c "$module" > "$temp_module" 2>/dev/null
            fi
            
            # Extract version from module
            version=$(modinfo "$temp_module" 2>/dev/null | grep "^version:" | awk '{print $2}' | head -1)
            
            # Cleanup
            if [[ "$temp_module" == /tmp/nvidia_temp_* ]]; then
                rm -f "$temp_module"
            fi
            
            if [ -n "$version" ]; then
                echo "$version"
                return 0
            fi
        fi
    fi
    
    # Method 3: Check from apt/dpkg for NVIDIA driver package
    if command -v apt-cache &> /dev/null; then
        version=$(apt-cache policy nvidia-driver 2>/dev/null | grep "Candidate:" | awk '{print $2}' | cut -d'-' -f1)
        if [ -n "$version" ] && [ "$version" != "(none)" ]; then
            echo "$version"
            return 0
        fi
    fi
    
    # Method 4: Try reading from X11 log if X is running
    if [ -f "/var/log/Xorg.0.log" ]; then
        version=$(grep "NVIDIA.*Driver" /var/log/Xorg.0.log 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    fi
    
    echo "unknown"
}

# Function to find all NVIDIA kernel modules for current kernel
find_nvidia_modules() {
    local modules=()
    
    # Search in standard locations
    local locations=(
        "/lib/modules/$KERNEL_VERSION/updates/dkms"
        "/lib/modules/$KERNEL_VERSION/kernel/drivers/video"
        "/lib/modules/$KERNEL_VERSION/extra"
        "/lib/modules/$KERNEL_VERSION/updates"
    )
    
    # Module names to search for
    local module_names=("nvidia" "nvidia-modeset" "nvidia-drm" "nvidia-uvm" "nvidia-peermem")
    
    for location in "${locations[@]}"; do
        if [ -d "$location" ]; then
            # Find both compressed and uncompressed versions
            for module_name in "${module_names[@]}"; do
                # Uncompressed
                if [ -f "$location/${module_name}.ko" ]; then
                    modules+=("$location/${module_name}.ko")
                fi
                # zstd compressed
                if [ -f "$location/${module_name}.ko.zst" ]; then
                    modules+=("$location/${module_name}.ko.zst")
                fi
                # xz compressed
                if [ -f "$location/${module_name}.ko.xz" ]; then
                    modules+=("$location/${module_name}.ko.xz")
                fi
            done
        fi
    done
    
    # Also search for DKMS built modules
    if [ -d "/var/lib/dkms/nvidia" ]; then
        local dkms_version=$(ls -1d /var/lib/dkms/nvidia/*/ 2>/dev/null | grep -oP '(?<=/nvidia/)[^/]+' | sort -V | tail -1)
        if [ -n "$dkms_version" ]; then
            local dkms_location="/var/lib/dkms/nvidia/$dkms_version/$KERNEL_VERSION/x86_64/module"
            if [ -d "$dkms_location" ]; then
                for module_name in "${module_names[@]}"; do
                    if [ -f "$dkms_location/${module_name}.ko" ]; then
                        modules+=("$dkms_location/${module_name}.ko")
                    fi
                    if [ -f "$dkms_location/${module_name}.ko.zst" ]; then
                        modules+=("$dkms_location/${module_name}.ko.zst")
                    fi
                    if [ -f "$dkms_location/${module_name}.ko.xz" ]; then
                        modules+=("$dkms_location/${module_name}.ko.xz")
                    fi
                done
            fi
        fi
    fi
    
    # Remove duplicates and print
    printf '%s\n' "${modules[@]}" | sort -u
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root (use sudo)"
    exit 1
fi

print_status "NVIDIA Secure Boot Signing Automation Script (Improved)"
echo "=========================================================="
echo ""

# Step 1: Install required packages
print_status "Step 1: Installing required packages..."
apt-get update -qq 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get install -y openssl mokutil kmod sbsigntool zstd xz-utils 2>/dev/null
if ! apt-get install -y linux-headers-$KERNEL_VERSION >/dev/null 2>&1; then
    print_warning "Could not install linux-headers, will try to find sign-file from existing sources"
fi
print_success "Required packages installed"
echo ""

# Step 2: Check Secure Boot status
print_status "Step 2: Checking Secure Boot status..."
if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
    print_warning "Secure Boot is currently ENABLED"
    print_warning "Note: On some systems, Secure Boot can be enabled for signing process"
    print_warning "The script will attempt to sign modules anyway"
else
    print_success "Secure Boot is currently disabled (recommended for signing process)"
fi
echo ""

# Step 3: Detect NVIDIA driver version (WITHOUT nvidia-smi)
print_status "Step 3: Detecting NVIDIA driver version from filesystem..."

NVIDIA_VERSION=$(detect_nvidia_driver_version)
if [ "$NVIDIA_VERSION" = "unknown" ]; then
    print_warning "Could not automatically detect NVIDIA driver version"
    print_status "Attempting manual detection from installed packages..."
    
    if command -v apt-cache &> /dev/null; then
        NVIDIA_VERSION=$(apt-cache search nvidia-driver | grep "^nvidia-driver " | tail -1 | awk '{print $1}' | grep -oP '\d+')
    fi
    
    if [ "$NVIDIA_VERSION" = "unknown" ] || [ -z "$NVIDIA_VERSION" ]; then
        print_error "Could not detect NVIDIA driver version"
        print_error "Please run: dpkg -l | grep nvidia"
        print_error "And tell me the driver version"
        exit 1
    fi
fi

print_status "Detected NVIDIA Driver Version: $NVIDIA_VERSION"
print_status "Kernel Version: $KERNEL_VERSION"
echo ""

# Step 4: Find all NVIDIA kernel modules
print_status "Step 4: Locating NVIDIA kernel modules..."

# Use function to find all modules
MODULES_OUTPUT=$(find_nvidia_modules)

if [ -z "$MODULES_OUTPUT" ]; then
    print_error "No NVIDIA kernel modules found!"
    print_error "This might mean:"
    print_error "  - NVIDIA driver is not installed"
    print_error "  - Modules are in an unexpected location"
    print_error ""
    print_error "Try running: find /lib/modules -name 'nvidia*.ko*'"
    exit 1
fi

# Convert to array
NVIDIA_MODULES=()
while IFS= read -r module; do
    if [ -n "$module" ]; then
        NVIDIA_MODULES+=("$module")
    fi
done <<< "$MODULES_OUTPUT"

print_success "Found ${#NVIDIA_MODULES[@]} NVIDIA kernel module(s):"
for module in "${NVIDIA_MODULES[@]}"; do
    echo "  - $module"
done
echo ""

# Step 5: Generate Machine Owner Key (MOK)
print_status "Step 5: Generating Machine Owner Key (MOK)..."

if [ -f "$MOK_PRIV" ] && [ -f "$MOK_DER" ]; then
    print_warning "MOK keys already exist at $MOK_DIR"
    read -p "Do you want to use existing keys? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Generating new MOK keys..."
        mkdir -p "$MOK_DIR"
        
        openssl req -new -x509 -newkey rsa:2048 \
            -keyout "$MOK_PRIV" \
            -outform DER \
            -out "$MOK_DER" \
            -days 36500 \
            -subj "/CN=NVIDIA Secure Boot MOK/" \
            -nodes \
            -addext "extendedKeyUsage=codeSigning,1.3.6.1.4.1.311.10.3.6,1.3.6.1.4.1.2312.16.1.2" \
            2>/dev/null
        
        openssl x509 -in "$MOK_DER" -inform DER -outform PEM -out "$MOK_PEM" 2>/dev/null
        
        chmod 600 "$MOK_PRIV"
        chmod 644 "$MOK_DER" "$MOK_PEM"
        
        print_success "New MOK keys generated"
    else
        print_success "Using existing MOK keys"
    fi
else
    print_status "Generating new MOK keys..."
    mkdir -p "$MOK_DIR"
    
    openssl req -new -x509 -newkey rsa:2048 \
        -keyout "$MOK_PRIV" \
        -outform DER \
        -out "$MOK_DER" \
        -days 36500 \
        -subj "/CN=NVIDIA Secure Boot MOK/" \
        -nodes \
        -addext "extendedKeyUsage=codeSigning,1.3.6.1.4.1.311.10.3.6,1.3.6.1.4.1.2312.16.1.2" \
        2>/dev/null
    
    openssl x509 -in "$MOK_DER" -inform DER -outform PEM -out "$MOK_PEM" 2>/dev/null
    
    chmod 600 "$MOK_PRIV"
    chmod 644 "$MOK_DER" "$MOK_PEM"
    
    print_success "MOK keys generated successfully"
fi
echo ""

# Step 6: Find sign-file script
print_status "Step 6: Locating sign-file script..."

SIGN_FILE_SCRIPT=""
for candidate in \
    "/usr/src/linux-headers-$KERNEL_VERSION/scripts/sign-file" \
    "/lib/modules/$KERNEL_VERSION/build/scripts/sign-file" \
    "/lib/modules/$KERNEL_VERSION/source/scripts/sign-file"; do
    if [ -f "$candidate" ]; then
        SIGN_FILE_SCRIPT="$candidate"
        break
    fi
done

if [ -z "$SIGN_FILE_SCRIPT" ]; then
    print_error "Could not find sign-file script"
    print_error "Trying to reinstall linux-headers..."
    apt-get install --reinstall -y linux-headers-$KERNEL_VERSION >/dev/null 2>&1
    
    if [ ! -f "/usr/src/linux-headers-$KERNEL_VERSION/scripts/sign-file" ]; then
        print_error "Failed to find or install sign-file script"
        exit 1
    fi
    SIGN_FILE_SCRIPT="/usr/src/linux-headers-$KERNEL_VERSION/scripts/sign-file"
fi

print_success "Found sign-file at: $SIGN_FILE_SCRIPT"
echo ""

# Step 7: Sign NVIDIA kernel modules
print_status "Step 7: Signing NVIDIA kernel modules..."

for module in "${NVIDIA_MODULES[@]}"; do
    MODULE_TO_SIGN="$module"
    TEMP_MODULE=""
    
    if [[ "$module" == *.zst ]]; then
        print_status "Decompressing $module..."
        TEMP_MODULE="${module%.zst}"
        zstd -d "$module" -o "$TEMP_MODULE" --force 2>/dev/null
        MODULE_TO_SIGN="$TEMP_MODULE"
    elif [[ "$module" == *.xz ]]; then
        print_status "Decompressing $module..."
        TEMP_MODULE="${module%.xz}"
        xz -d -k "$module" 2>/dev/null
        MODULE_TO_SIGN="$TEMP_MODULE"
    fi
    
    print_status "Signing: $(basename $MODULE_TO_SIGN)"
    if "$SIGN_FILE_SCRIPT" sha256 "$MOK_PRIV" "$MOK_DER" "$MODULE_TO_SIGN" 2>/dev/null; then
        print_success "Signed successfully"
    else
        print_error "Failed to sign $MODULE_TO_SIGN"
    fi
    
    # Recompress if it was compressed
    if [[ "$module" == *.zst ]] && [ -n "$TEMP_MODULE" ]; then
        print_status "Recompressing with zstd..."
        zstd "$TEMP_MODULE" -o "$module" --force 2>/dev/null
        rm -f "$TEMP_MODULE"
    elif [[ "$module" == *.xz ]] && [ -n "$TEMP_MODULE" ]; then
        print_status "Recompressing with xz..."
        xz -z -k "$TEMP_MODULE" --force 2>/dev/null
        mv "${TEMP_MODULE}.xz" "$module" 2>/dev/null
        rm -f "$TEMP_MODULE"
    fi
    
    print_success "Completed: $(basename $module)"
done
echo ""

# Step 8: Configure DKMS
print_status "Step 8: Configuring DKMS for automatic module signing..."

if [ -f "$DKMS_CONFIG" ]; then
    if ! grep -q "mok_signing_key" "$DKMS_CONFIG" 2>/dev/null; then
        cat >> "$DKMS_CONFIG" << EOF

# MOK signing configuration for Secure Boot
mok_signing_key="$MOK_PRIV"
mok_certificate="$MOK_DER"
EOF
        print_success "DKMS configuration updated"
    else
        print_warning "DKMS already configured for signing"
    fi
else
    mkdir -p /etc/dkms
    cat > "$DKMS_CONFIG" << EOF
# DKMS configuration for automatic module signing
mok_signing_key="$MOK_PRIV"
mok_certificate="$MOK_DER"
EOF
    print_success "DKMS configuration created"
fi
echo ""

# Step 9: Enroll MOK key
print_status "Step 9: Enrolling MOK key into system firmware..."

if mokutil --list-enrolled 2>/dev/null | grep -q "NVIDIA"; then
    print_warning "MOK key appears to be already enrolled"
else
    print_status "Importing MOK key..."
    if mokutil --import "$MOK_DER" 2>&1; then
        print_success "MOK key import request created"
        echo ""
        print_warning "IMPORTANT: On next reboot, you will see a blue MOK Manager screen"
        print_warning "Follow these steps:"
        print_warning "  1. Select 'Enroll MOK'"
        print_warning "  2. Select 'Continue'"
        print_warning "  3. Select 'Yes' to enroll the key"
        print_warning "  4. Enter the password you just set"
        print_warning "  5. Select 'Reboot'"
    else
        print_error "Failed to import MOK key"
    fi
fi
echo ""

# Step 10: Create helper scripts
print_status "Step 10: Creating helper scripts..."

cat > /usr/local/bin/nvidia-secure-boot-resign << 'EOFSCRIPT'
#!/bin/bash
# Re-sign NVIDIA modules after driver updates

MOK_PRIV="/var/lib/shim-signed/mok/MOK.priv"
MOK_DER="/var/lib/shim-signed/mok/MOK.der"
KERNEL_VERSION=$(uname -r)

echo "Re-signing NVIDIA kernel modules..."

SIGN_FILE="/usr/src/linux-headers-$KERNEL_VERSION/scripts/sign-file"
if [ ! -f "$SIGN_FILE" ]; then
    SIGN_FILE="/lib/modules/$KERNEL_VERSION/build/scripts/sign-file"
fi

if [ ! -f "$SIGN_FILE" ]; then
    echo "ERROR: sign-file script not found"
    exit 1
fi

find /lib/modules/$KERNEL_VERSION -name "nvidia*.ko*" 2>/dev/null | while read module; do
    if [ -z "$module" ]; then
        continue
    fi
    
    echo "Processing: $module"
    
    if [[ "$module" == *.zst ]]; then
        TEMP="${module%.zst}"
        zstd -d "$module" -o "$TEMP" --force 2>/dev/null
        $SIGN_FILE sha256 "$MOK_PRIV" "$MOK_DER" "$TEMP" 2>/dev/null
        zstd "$TEMP" -o "$module" --force 2>/dev/null
        rm -f "$TEMP"
    elif [[ "$module" == *.xz ]]; then
        TEMP="${module%.xz}"
        xz -d -k "$module" 2>/dev/null
        $SIGN_FILE sha256 "$MOK_PRIV" "$MOK_DER" "$TEMP" 2>/dev/null
        xz -z "$TEMP" --force 2>/dev/null
        mv "${TEMP}.xz" "$module" 2>/dev/null
        rm -f "$TEMP"
    else
        $SIGN_FILE sha256 "$MOK_PRIV" "$MOK_DER" "$module" 2>/dev/null
    fi
done

echo "Re-signing complete!"
EOFSCRIPT

chmod +x /usr/local/bin/nvidia-secure-boot-resign
print_success "Helper script created"
echo ""

# Final summary
echo "=============================================================="
print_success "NVIDIA Secure Boot signing process COMPLETE!"
echo "=============================================================="
echo ""
print_status "Summary of what was done:"
echo "  ✓ Detected NVIDIA driver version: $NVIDIA_VERSION"
echo "  ✓ Found and signed ${#NVIDIA_MODULES[@]} kernel module(s)"
echo "  ✓ Generated MOK key pair"
echo "  ✓ Configured DKMS for automatic signing"
echo "  ✓ Imported MOK key for enrollment"
echo ""
print_status "NEXT STEPS:"
echo "  1. Reboot your system: sudo reboot"
echo "  2. During boot, enroll MOK key in the blue MOK Manager screen"
echo "  3. After enrolling, enable Secure Boot in BIOS/UEFI"
echo "  4. Boot back into Ubuntu and verify: mokutil --sb-state"
echo ""
print_status "To verify modules are signed:"
echo "  modinfo nvidia | grep sig_id"
echo ""
print_status "After NVIDIA driver updates, re-sign modules with:"
echo "  sudo /usr/local/bin/nvidia-secure-boot-resign"
echo ""

exit 0
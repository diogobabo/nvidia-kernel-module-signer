# NVIDIA Kernel Module Signer

A simple, automated Bash script to sign NVIDIA kernel modules for Secure Boot on Ubuntu and similar Linux systems. This tool helps you use your NVIDIA GPU while keeping Secure Boot enabled.

## Features

- **Automatic Detection** - Finds your NVIDIA driver version without requiring nvidia-smi
- **Multiple Format Support** - Handles compressed (.zst, .xz) and uncompressed kernel modules
- **DKMS Integration** - Automatically configures DKMS to sign modules on updates
- **MOK Management** - Generates and enrolls Machine Owner Keys for Secure Boot
- **Color-Coded Output** - Easy-to-read status messages
- **Resigning Script** - Creates a script for easy re-signing after driver updates

## Prerequisites

Before using this script, make sure you have:

- Ubuntu or similar Linux distribution with Secure Boot enabled
- NVIDIA drivers installed (any version)
- Root/sudo access

## How to Use

**Note:** This script worked for me, but I'm not the most experienced Linux user. Use it at your own risk. Always back up your data and read through the script before running it.

### Step 1: Download the Script

Clone this repository or download the script directly:

```bash
git clone https://github.com/diogobabo/nvidia-kernel-module-signer.git
cd nvidia-kernel-module-signer
```

### Step 2: Make the Script Executable

```bash
sudo chmod +x nvidia-kernel-module-signer.sh
```

### Step 3: Run the Script

```bash
sudo bash nvidia-kernel-module-signer.sh
```

### Step 4: Follow the On-Screen Instructions

The script will:
1. Check if required tools are installed
2. Detect your NVIDIA driver version
3. Create signing keys (if they don't exist)
4. Sign all NVIDIA kernel modules
5. Configure DKMS for automatic signing
6. Prompt you to enroll the MOK (Machine Owner Key)

### Step 5: Enroll the MOK Key

After running the script, you'll need to reboot and enroll the MOK key:

1. Restart your computer
2. You'll see a blue MOK management screen
3. Select "Enroll MOK"
4. Enter the password you set during the script execution
5. Reboot again

### If you update the NVIDIA drivers

If you update your NVIDIA drivers in the future, simply use the resigning script that will be created in `/usr/local/bin/nvidia-secure-boot-resign` to re-sign the modules without needing to go through the entire process again.

## What to Expect

After successfully running the script and enrolling the MOK:

- Your NVIDIA drivers will work with Secure Boot enabled
- Your system remains secure with Secure Boot
- You can easily re-sign your modules after driver updates

## Disclaimer

This script worked on my system, but I'm not an expert. Use at your own risk.

## Contributing

Contributions are welcome! If you'd like to improve this script:

1. Fork the repository
2. Make your changes
3. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support
Remember: I'm learning too, so community help is appreciated!


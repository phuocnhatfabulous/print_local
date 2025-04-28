#!/bin/bash

PL_HOME="/opt/print_local"
NODEJS_DOWNLOAD_URL=https://nodejs.org/dist/v23.9.0/node-v23.9.0-linux-x64.tar.xz
NODEJS_HOME=/usr/share/node
NODEJS_BIN_PATH=/usr/share/node/bin

# Ensure script runs as root
[ "$USER" != 'root' ] && exec sudo "$0"

# --- Function Definitions ---

function install_printlocal {
    # Check if print_local service is already running
    service print_local status >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo "Print local available on this device, please uninstall it first!"
        exit 1
    fi

    echo "Find package url with format https://resource.eton.vn/warehouse_share/packages/print_local-prod-***.tar.gz"
    printf "Enter package url: "
    read -r PL_URL # Use -r to prevent backslash interpretation
    
    # Check if the Chrome version ≠ 135, will be reinstalled
    CURRENT_VERSION=$(google-chrome --version | grep -oE '[0-9.]+')
    TARGET_VERSION="135.0.7049.84"

    # Prepare to check if Chrome is installed
    if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]]; then
        echo "The current version of Chrome is $CURRENT_VERSION, no need to reinstall."
    else
        echo "The current version of Chrome is $CURRENT_VERSION, reinstalling..."
        wget https://resource.eton.vn/warehouse_share/Software/google-chrome-stable_135.0.7049.84-1_amd64.zip -O chrome.zip
        unzip chrome.zip
        sudo dpkg -i google-chrome-stable_135.0.7049.84-1_amd64.deb
    fi

    # Check if Node.js and npm are installed
    if ! (node -v >/dev/null && npm -v >/dev/null); then
        echo "Installing nodejs..."
        mkdir -p "$NODEJS_HOME"
        # Use curl with -L to follow redirects and -sS for silent errors
        curl -sSL -o /tmp/nodejs.tar.xz "$NODEJS_DOWNLOAD_URL" || { echo "Failed to download Node.js"; exit 1; }
        tar -xf /tmp/nodejs.tar.xz --strip-components=1 -C "$NODEJS_HOME" || { echo "Failed to extract Node.js"; exit 1; }
        rm -f /tmp/nodejs.tar.xz # Clean up download

        # Force remove existing symlinks if they exist
        rm -f /usr/bin/node
        rm -f /usr/bin/npm

        # Create new symlinks
        ln -s "$NODEJS_BIN_PATH/node" /usr/bin/node
        ln -s "$NODEJS_BIN_PATH/npm" /usr/bin/npm

        # Verify installation
        echo "Node.js installation complete:"
        node -v && npm -v
    fi

    # Check if the provided package URL is valid
    if curl --output /dev/null --silent --head --fail "$PL_URL"; then
        echo "Downloading print_local package..."
        curl -sSL -o /tmp/print_local.tar.gz "$PL_URL" || { echo "Failed to download print_local package"; exit 1; }

        echo "Extracting print_local package..."
        mkdir -p "$PL_HOME"
        tar -xzf /tmp/print_local.tar.gz --strip-components=1 -C "$PL_HOME" || { echo "Failed to extract print_local package"; exit 1; }
        rm -f /tmp/print_local.tar.gz # Clean up download

        echo "Installing printer dependencies..."
        cd "$PL_HOME/printer" || { echo "Failed to change directory to $PL_HOME/printer"; exit 1; }
        npm install || { echo "npm install failed"; exit 1; }

        echo "Configuring systemd service..."
        # Use cat with EOF for multiline strings
        cat > /etc/systemd/system/print_local.service <<EOF
[Unit]
Description=Service trigger printor
After=multi-user.target

[Service]
User=root
ExecStart=/usr/bin/node /opt/print_local/printer/index.js
Restart=always
WorkingDirectory=/opt/print_local/printer
StandardError=syslog
StandardOutput=syslog
SyslogIdentifier=eton_print_local

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload

        echo "Configuring rsyslog..."
        cat > /etc/rsyslog.d/51-eton-print-local.conf <<EOF
if (\$programname == 'eton_print_local' and \$msg contains 'error') then {
  /var/log/eton-print-local-error.log
  @10.0.19.249:514;RSYSLOG_SyslogProtocol23Format
}
& stop
EOF
        service rsyslog restart || echo "Warning: Failed to restart rsyslog. Manual restart might be needed."

        echo "Enabling and starting print_local service..."
        systemctl enable print_local.service
        service print_local start

        clear
        echo "Install complete!"
    else
        echo "Package URL not found or invalid: $PL_URL"
        exit 1
    fi
}

function uninstall_printlocal {
    echo "Stopping print_local service..."
    service print_local stop >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        # Check if service file exists even if service wasn't running
        if [[ ! -f /etc/systemd/system/print_local.service ]]; then
            echo "Print local does not appear to be installed (service file missing)."
            exit 1
        else
             echo "Warning: Service was not running, but attempting cleanup anyway."
        fi
    fi

    echo "Disabling print_local service..."
    systemctl disable print_local.service >/dev/null 2>&1 # Ignore errors if already disabled

    echo "Removing files and directories..."
    rm -rf "$PL_HOME"
    rm -f /usr/bin/node
    rm -f /usr/bin/npm
    rm -rf "$NODEJS_HOME"
    rm -f /etc/systemd/system/print_local.service
    rm -f /etc/rsyslog.d/51-eton-print-local.conf

    echo "Reloading systemd daemon..."
    systemctl daemon-reload

    echo "Restarting rsyslog..."
    service rsyslog restart || echo "Warning: Failed to restart rsyslog. Manual restart might be needed."

    echo "Print local has been removed from this device!"
}

function setting_paper_size {
    # Ensure cups service is running before modifying
    if ! systemctl is-active --quiet cups; then
        echo "CUPS service is not running. Starting it..."
        service cups start || { echo "Failed to start CUPS service."; exit 1; }
    fi

    echo "Removing existing INTEM alias if it exists..."
    lpadmin -x INTEM 2>/dev/null # Suppress error if it doesn't exist

    PRINTER_CONFIG_PATH="/etc/cups/printers.conf"
    if [[ ! -f "$PRINTER_CONFIG_PATH" ]]; then
        echo "Error: CUPS configuration file not found at $PRINTER_CONFIG_PATH"
        exit 1
    fi

    echo "Renaming printers in $PRINTER_CONFIG_PATH..."
    # Use more specific sed patterns if possible, be cautious with broad replacements
    sed -i 's/<Printer XP-420B>/<Printer INTEM420B>/g' "$PRINTER_CONFIG_PATH"
    sed -i 's/<Printer XP-480B>/<Printer INTEM480B>/g' "$PRINTER_CONFIG_PATH"
    sed -i 's/<Printer TSC TE200>/<Printer INTEMTE200>/g' "$PRINTER_CONFIG_PATH"
    sed -i 's/<Printer TSC TE210>/<Printer INTEMTE210>/g' "$PRINTER_CONFIG_PATH"
    sed -i 's/<Printer TSC MH341>/<Printer INTEMMH341>/g' "$PRINTER_CONFIG_PATH"
    sed -i 's/<Printer TSC MH241>/<Printer INTEMmh241>/g' "$PRINTER_CONFIG_PATH" # Note lowercase 'mh'
    sed -i 's/Info XP-420B/Info INTEM420B/g' "$PRINTER_CONFIG_PATH"
    sed -i 's/Info XP-480B/Info INTEM480B/g' "$PRINTER_CONFIG_PATH"
    sed -i 's/Info TSC TE200/Info INTEMTE200/g' "$PRINTER_CONFIG_PATH"
    sed -i 's/Info TSC TE210/Info INTEMTE210/g' "$PRINTER_CONFIG_PATH"
    sed -i 's/Info TSC MH341/Info INTEMMH341/g' "$PRINTER_CONFIG_PATH"
    sed -i 's/Info TSC MH241/Info INTEMMH241/g' "$PRINTER_CONFIG_PATH" # Note lowercase 'mh'

    echo "Removing old PPD files..."
    rm -f /etc/cups/ppd/TE*
    rm -f /etc/cups/ppd/INTEM* # Remove potentially existing renamed ones first

    PPD_DIR="/etc/cups/ppd"
    mkdir -p "$PPD_DIR" # Ensure PPD directory exists

    echo "Downloading new PPD files..."
    # Add error checking for curl downloads
    curl -SL -o "$PPD_DIR/INTEMMH241.ppd" https://resource.eton.vn/warehouse_share/drivers/ppd/TSC-MH241.ppd.txt || echo "Warning: Failed to download INTEMMH241 PPD"
    curl -SL -o "$PPD_DIR/INTEMMH341.ppd" https://resource.eton.vn/warehouse_share/drivers/ppd/TSC-MH341.ppd.txt || echo "Warning: Failed to download INTEMMH341 PPD"
    curl -SL -o "$PPD_DIR/INTEMTE210.ppd" https://resource.eton.vn/warehouse_share/drivers/ppd/TSC-TE210.ppd.txt || echo "Warning: Failed to download INTEMTE210 PPD"
    curl -SL -o "$PPD_DIR/INTEMTE200.ppd" https://resource.eton.vn/warehouse_share/drivers/ppd/TSC-TE200.ppd.txt || echo "Warning: Failed to download INTEMTE200 PPD"
    curl -SL -o "$PPD_DIR/INTEM420B.ppd" https://resource.eton.vn/warehouse_share/drivers/ppd/XP-420B.ppd.txt || echo "Warning: Failed to download INTEM420B PPD"
    curl -SL -o "$PPD_DIR/INTEM480B.ppd" https://resource.eton.vn/warehouse_share/drivers/ppd/XP-480B.ppd.txt || echo "Warning: Failed to download INTEM480B PPD"

    # Map printer models to desired names
    declare -A printers=(
        ["XP-420B"]="INTEM420B"
        ["XP-480B"]="INTEM480B"
        ["MH341"]="INTEMMH341" # Assuming MH341 maps to INTEMMH341 PPD
        ["MH241"]="INTEMMH241" # Assuming MH241 maps to INTEMMH241 PPD
        ["TE200"]="INTEMTE200"
        ["TE210"]="INTEMTE210"
    )

    echo "Detecting and configuring USB printers..."
    # Use mapfile to read USB printer URIs
    mapfile -t usb_printers < <(lpinfo -v | awk '/^direct usb/ {print $2}')

    if [[ ${#usb_printers[@]} -eq 0 ]]; then
        echo "No direct USB printers detected by lpinfo -v."
    else
        # Iterate through detected USB printers
        for uri in "${usb_printers[@]}"; do
            # Iterate through known models
            for model in "${!printers[@]}"; do
                # Check if the URI contains the model string
                if [[ "$uri" == *"$model"* ]]; then
                    printer_name="${printers[$model]}"
                    ppd_path="${PPD_DIR}/${printer_name}.ppd"

                    if [[ -f "$ppd_path" ]]; then
                        echo "⚙️ Configuring printer: $printer_name → $uri"
                        # Remove existing printer queue with this name, if any
                        lpadmin -x "$printer_name" 2>/dev/null
                        # Add the printer
                        lpadmin -p "$printer_name" -E -v "$uri" -P "$ppd_path" -o printer-is-shared=false || echo "Warning: Failed to configure $printer_name"
                    else
                        echo "Warning: PPD file not found for $printer_name at $ppd_path. Skipping configuration."
                    fi
                    # Assume one match per URI is sufficient
                    break
                fi
            done
        done
        echo "✅ Printer configuration attempt finished."
    fi

    echo "Restarting CUPS service..."
    service cups restart || { echo "Error: Failed to restart CUPS service."; exit 1; }

    echo "Paper size setup complete!"
}

function select_default_printer {
    # Ensure cups service is running
    if ! systemctl is-active --quiet cups; then
        echo "CUPS service is not running. Starting it..."
        service cups start || { echo "Failed to start CUPS service."; exit 1; }
    fi

    echo "=== STEP 1: Removing existing 'INTEM' alias ==="
    lpadmin -x INTEM 2>/dev/null # Suppress error if it doesn't exist

    echo ""
    echo "=== STEP 2: Select printer for 'INTEM' alias and default ==="
    echo "Available printers:"

    # Get list of configured printer names
    mapfile -t printers < <(lpstat -p | awk '{print $2}')

    if [[ ${#printers[@]} -eq 0 ]]; then
        echo "No printers found configured in CUPS."
        exit 1
    fi

    # Display printers with numbers
    count=1
    for printer in "${printers[@]}"; do
        echo "  $count. $printer"
        ((count++))
    done

    # Prompt for selection
    read -rp "Enter the number of the printer to set as 'INTEM' and default: " selection

    # Validate selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt "${#printers[@]}" ]]; then
        echo "Invalid selection. Exiting."
        exit 1
    fi

    # Get the chosen printer name
    selected_printer="${printers[$((selection - 1))]}"
    echo "You selected: $selected_printer"

    echo ""
    echo "=== STEP 3: Assigning 'INTEM' alias and setting default ==="

    ALIAS="INTEM"
    # Get URI and PPD path for the selected printer
    URI=$(lpstat -v "$selected_printer" | awk -F': ' '{print $2}')
    PPD_GUESS="/etc/cups/ppd/${selected_printer}.ppd" # Guess PPD path based on name

    if [[ -z "$URI" ]]; then
        echo "Error: Could not determine URI for printer '$selected_printer'."
        exit 1
    fi

    if [[ ! -f "$PPD_GUESS" ]]; then
        echo "Error: Could not find PPD file at guessed location '$PPD_GUESS'."
        echo "Cannot create alias '$ALIAS'."
        exit 1
    fi

    echo "Creating alias '$ALIAS' for '$selected_printer'..."
    # Remove alias first in case it somehow exists for a different printer
    lpadmin -x "$ALIAS" 2>/dev/null
    # Create the new printer queue acting as an alias
    lpadmin -p "$ALIAS" -E -v "$URI" -P "$PPD_GUESS" -o printer-is-shared=false

    if [[ $? -eq 0 ]]; then
        echo "Alias '$ALIAS' created successfully for '$selected_printer'."
        echo "Setting '$ALIAS' as the default printer..."
        lpoptions -d "$ALIAS"
        if [[ $? -eq 0 ]]; then
             echo "Successfully set '$ALIAS' as the default printer."
        else
             echo "Error setting '$ALIAS' as the default printer."
             exit 1
        fi
    else
        echo "Error creating alias '$ALIAS' for printer '$selected_printer'."
        exit 1
    fi

    echo ""
    echo "Completed. Current default printer: $(lpstat -d)"
}

# --- Main Script Logic ---

PS3='Please enter your choice: '
options=(
    'Install print local'
    'Uninstall print local'
    'Configure Printers (Rename/Add PPDs/Detect USB)'
    'Select default printer (using INTEM alias)'
    'Exit'
)

select opt in "${options[@]}"; do
    case "$opt" in
        'Install print local')
            install_printlocal
            break
            ;;
        'Uninstall print local')
            uninstall_printlocal
            break
            ;;
        'Configure Printers (Rename/Add PPDs/Detect USB)')
            setting_paper_size # Renamed function for clarity
            break
            ;;
        'Select default printer (using INTEM alias)')
            select_default_printer
            break
            ;;
        'Exit')
            echo "Exiting."
            break
            ;;
        *)
            echo "Invalid option $REPLY"
            ;;
    esac
done

exit 0
